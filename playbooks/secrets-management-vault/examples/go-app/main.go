package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	vault "github.com/hashicorp/vault/api"
)

// VaultClient wrapper untuk HashiCorp Vault operations
type VaultClient struct {
	client     *vault.Client
	authMethod string
}

// NewVaultClient membuat Vault client baru
func NewVaultClient(vaultAddr, authMethod string) (*VaultClient, error) {
	config := vault.DefaultConfig()
	config.Address = vaultAddr

	client, err := vault.NewClient(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create vault client: %w", err)
	}

	vc := &VaultClient{
		client:     client,
		authMethod: authMethod,
	}

	if err := vc.authenticate(); err != nil {
		return nil, err
	}

	return vc, nil
}

// authenticate melakukan authentication ke Vault
func (vc *VaultClient) authenticate() error {
	switch vc.authMethod {
	case "approle":
		return vc.authenticateAppRole()
	case "kubernetes":
		return vc.authenticateKubernetes()
	case "token":
		return vc.authenticateToken()
	default:
		return fmt.Errorf("auth method tidak didukung: %s", vc.authMethod)
	}
}

// authenticateAppRole authenticate menggunakan AppRole
func (vc *VaultClient) authenticateAppRole() error {
	roleID := os.Getenv("VAULT_ROLE_ID")
	secretID := os.Getenv("VAULT_SECRET_ID")

	if roleID == "" || secretID == "" {
		return fmt.Errorf("VAULT_ROLE_ID dan VAULT_SECRET_ID harus diset")
	}

	log.Println("🔐 Authenticating ke Vault menggunakan AppRole...")

	data := map[string]interface{}{
		"role_id":   roleID,
		"secret_id": secretID,
	}

	resp, err := vc.client.Logical().Write("auth/approle/login", data)
	if err != nil {
		return fmt.Errorf("approle login failed: %w", err)
	}

	vc.client.SetToken(resp.Auth.ClientToken)
	log.Printf("✅ Authentication berhasil! Token TTL: %ds\n", resp.Auth.LeaseDuration)

	return nil
}

// authenticateKubernetes authenticate menggunakan Kubernetes ServiceAccount
func (vc *VaultClient) authenticateKubernetes() error {
	jwtBytes, err := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")
	if err != nil {
		return fmt.Errorf("failed to read service account token: %w", err)
	}

	role := os.Getenv("VAULT_ROLE")
	if role == "" {
		role = "myapp"
	}

	log.Printf("🔐 Authenticating ke Vault menggunakan Kubernetes auth (role: %s)...\n", role)

	data := map[string]interface{}{
		"jwt":  string(jwtBytes),
		"role": role,
	}

	resp, err := vc.client.Logical().Write("auth/kubernetes/login", data)
	if err != nil {
		return fmt.Errorf("kubernetes login failed: %w", err)
	}

	vc.client.SetToken(resp.Auth.ClientToken)
	log.Printf("✅ Authentication berhasil! Token TTL: %ds\n", resp.Auth.LeaseDuration)

	return nil
}

// authenticateToken menggunakan token langsung (dev only)
func (vc *VaultClient) authenticateToken() error {
	token := os.Getenv("VAULT_TOKEN")
	if token == "" {
		return fmt.Errorf("VAULT_TOKEN harus diset")
	}

	vc.client.SetToken(token)
	log.Println("✅ Menggunakan VAULT_TOKEN")

	return nil
}

// GetSecret fetch secret dari KV v2
func (vc *VaultClient) GetSecret(path, mountPoint string) (map[string]interface{}, error) {
	log.Printf("📖 Reading secret: %s/%s\n", mountPoint, path)

	secretPath := fmt.Sprintf("%s/data/%s", mountPoint, path)
	secret, err := vc.client.Logical().Read(secretPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read secret: %w", err)
	}

	if secret == nil {
		log.Printf("❌ Secret tidak ditemukan: %s\n", path)
		return nil, nil
	}

	data := secret.Data["data"].(map[string]interface{})
	metadata := secret.Data["metadata"].(map[string]interface{})
	version := metadata["version"]

	log.Printf("✅ Secret retrieved (version %v)\n", version)

	return data, nil
}

// GetDatabaseCredentials generate dynamic database credentials
func (vc *VaultClient) GetDatabaseCredentials(role string) (*DatabaseCredentials, error) {
	log.Printf("🔑 Generating dynamic database credentials untuk role: %s\n", role)

	credPath := fmt.Sprintf("database/creds/%s", role)
	secret, err := vc.client.Logical().Read(credPath)
	if err != nil {
		return nil, fmt.Errorf("failed to generate credentials: %w", err)
	}

	if secret == nil {
		return nil, fmt.Errorf("no credentials returned")
	}

	creds := &DatabaseCredentials{
		Username:      secret.Data["username"].(string),
		Password:      secret.Data["password"].(string),
		LeaseID:       secret.LeaseID,
		LeaseDuration: secret.LeaseDuration,
	}

	log.Println("✅ Dynamic credentials generated:")
	log.Printf("   Username: %s\n", creds.Username)
	log.Printf("   Lease duration: %ds\n", creds.LeaseDuration)
	log.Printf("   Lease ID: %s\n", creds.LeaseID)

	return creds, nil
}

// RenewToken renew Vault token
func (vc *VaultClient) RenewToken(increment int) error {
	log.Printf("🔄 Renewing token (increment: %ds)...\n", increment)

	secret, err := vc.client.Auth().Token().RenewSelf(increment)
	if err != nil {
		return fmt.Errorf("failed to renew token: %w", err)
	}

	log.Printf("✅ Token renewed. New TTL: %ds\n", secret.Auth.LeaseDuration)

	return nil
}

// RevokeLease revoke lease
func (vc *VaultClient) RevokeLease(leaseID string) error {
	log.Printf("🗑️  Revoking lease: %s\n", leaseID)

	if err := vc.client.Sys().Revoke(leaseID); err != nil {
		return fmt.Errorf("failed to revoke lease: %w", err)
	}

	log.Println("✅ Lease revoked")

	return nil
}

// DatabaseCredentials menyimpan dynamic database credentials
type DatabaseCredentials struct {
	Username      string
	Password      string
	LeaseID       string
	LeaseDuration int
}

func main() {
	log.SetFlags(0) // Disable timestamp, kita pakai emoji

	fmt.Println(strings.Repeat("=", 60))
	fmt.Println("🚀 Vault Go Demo Application")
	fmt.Println(strings.Repeat("=", 60))

	vaultAddr := os.Getenv("VAULT_ADDR")
	if vaultAddr == "" {
		vaultAddr = "http://localhost:8200"
	}

	authMethod := os.Getenv("VAULT_AUTH_METHOD")
	if authMethod == "" {
		authMethod = "approle"
	}

	fmt.Printf("Vault Address: %s\n", vaultAddr)
	fmt.Printf("Auth Method: %s\n", authMethod)
	fmt.Println()

	// Initialize Vault client
	vaultClient, err := NewVaultClient(vaultAddr, authMethod)
	if err != nil {
		log.Fatalf("❌ Failed to initialize Vault client: %v\n", err)
	}

	// Example 1: Fetch static secrets
	fmt.Println()
	fmt.Println(strings.Repeat("=", 60))
	fmt.Println("Example 1: Static Secrets (KV v2)")
	fmt.Println(strings.Repeat("=", 60))

	config, err := vaultClient.GetSecret("myapp/config", "secret")
	if err != nil {
		log.Printf("❌ Error reading secret: %v\n", err)
	}

	if config != nil {
		fmt.Println("\n📦 Application Config:")
		for key, value := range config {
			displayValue := value
			if key == "password" || key == "api_key" || key == "token" {
				displayValue = "***"
			}
			fmt.Printf("   %s: %v\n", key, displayValue)
		}
	}

	// Example 2: Dynamic database credentials
	fmt.Println()
	fmt.Println(strings.Repeat("=", 60))
	fmt.Println("Example 2: Dynamic Database Credentials")
	fmt.Println(strings.Repeat("=", 60))

	// Uncomment jika sudah setup database secrets engine
	// dbCreds, err := vaultClient.GetDatabaseCredentials("myapp-role")
	// if err != nil {
	// 	log.Printf("❌ Error generating credentials: %v\n", err)
	// } else {
	// 	fmt.Println("\n🗄️  Database Connection String:")
	// 	fmt.Printf("   postgresql://%s:***@postgres:5432/mydb\n", dbCreds.Username)
	// }

	// Example 3: Token renewal
	fmt.Println()
	fmt.Println(strings.Repeat("=", 60))
	fmt.Println("Example 3: Token Renewal")
	fmt.Println(strings.Repeat("=", 60))

	if err := vaultClient.RenewToken(3600); err != nil {
		log.Printf("❌ Error renewing token: %v\n", err)
	}

	// Simulate application runtime
	fmt.Println()
	fmt.Println(strings.Repeat("=", 60))
	fmt.Println("✅ Application running...")
	fmt.Println("Press Ctrl+C to exit")
	fmt.Println(strings.Repeat("=", 60))

	// Graceful shutdown handler
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Periodic token renewal
	ticker := time.NewTicker(10 * time.Minute)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			// Renew token setiap 10 menit
			if err := vaultClient.RenewToken(3600); err != nil {
				log.Printf("❌ Error renewing token: %v\n", err)
			}
		case <-sigChan:
			fmt.Println("\n\n👋 Shutting down gracefully...")
			cancel()
			return
		case <-ctx.Done():
			return
		}
	}
}
