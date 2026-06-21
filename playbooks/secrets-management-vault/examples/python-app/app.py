#!/usr/bin/env python3
"""
Contoh aplikasi Python yang menggunakan HashiCorp Vault
untuk fetch secrets secara secure.

Dependencies: hvac, requests
Install: pip install hvac requests
"""

import os
import sys
import hvac
import time
from typing import Dict, Any


class VaultClient:
    """Wrapper untuk HashiCorp Vault operations"""
    
    def __init__(self, vault_addr: str, auth_method: str = "approle"):
        self.vault_addr = vault_addr
        self.auth_method = auth_method
        self.client = hvac.Client(url=vault_addr)
        self._authenticate()
    
    def _authenticate(self):
        """Authenticate ke Vault menggunakan AppRole atau Kubernetes auth"""
        
        if self.auth_method == "approle":
            # AppRole: pakai RoleID & SecretID
            role_id = os.getenv("VAULT_ROLE_ID")
            secret_id = os.getenv("VAULT_SECRET_ID")
            
            if not role_id or not secret_id:
                raise ValueError("VAULT_ROLE_ID dan VAULT_SECRET_ID harus diset")
            
            print(f"🔐 Authenticating ke Vault menggunakan AppRole...")
            response = self.client.auth.approle.login(
                role_id=role_id,
                secret_id=secret_id
            )
            
            self.client.token = response["auth"]["client_token"]
            print(f"✅ Authentication berhasil! Token TTL: {response['auth']['lease_duration']}s")
        
        elif self.auth_method == "kubernetes":
            # Kubernetes: pakai ServiceAccount token
            with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as f:
                jwt = f.read()
            
            role = os.getenv("VAULT_ROLE", "myapp")
            
            print(f"🔐 Authenticating ke Vault menggunakan Kubernetes auth (role: {role})...")
            response = self.client.auth.kubernetes.login(
                role=role,
                jwt=jwt
            )
            
            self.client.token = response["auth"]["client_token"]
            print(f"✅ Authentication berhasil! Token TTL: {response['auth']['lease_duration']}s")
        
        elif self.auth_method == "token":
            # Development: langsung pakai token
            token = os.getenv("VAULT_TOKEN")
            if not token:
                raise ValueError("VAULT_TOKEN harus diset")
            
            self.client.token = token
            print(f"✅ Menggunakan VAULT_TOKEN")
        
        else:
            raise ValueError(f"Auth method tidak didukung: {self.auth_method}")
    
    def get_secret(self, path: str, mount_point: str = "secret") -> Dict[str, Any]:
        """
        Fetch secret dari KV v2 secrets engine
        
        Args:
            path: Path ke secret (tanpa 'secret/data/' prefix)
            mount_point: Mount point dari secrets engine
        
        Returns:
            Dictionary berisi secret data
        """
        print(f"📖 Reading secret: {mount_point}/{path}")
        
        try:
            response = self.client.secrets.kv.v2.read_secret_version(
                path=path,
                mount_point=mount_point
            )
            
            data = response["data"]["data"]
            metadata = response["data"]["metadata"]
            
            print(f"✅ Secret retrieved (version {metadata['version']})")
            return data
        
        except hvac.exceptions.InvalidPath:
            print(f"❌ Secret tidak ditemukan: {path}")
            return {}
        except Exception as e:
            print(f"❌ Error reading secret: {e}")
            raise
    
    def get_database_credentials(self, role: str) -> Dict[str, str]:
        """
        Generate dynamic database credentials
        
        Args:
            role: Database role name
        
        Returns:
            Dictionary dengan username, password, dan lease info
        """
        print(f"🔑 Generating dynamic database credentials untuk role: {role}")
        
        try:
            response = self.client.secrets.database.generate_credentials(
                name=role
            )
            
            creds = {
                "username": response["data"]["username"],
                "password": response["data"]["password"],
                "lease_id": response["lease_id"],
                "lease_duration": response["lease_duration"]
            }
            
            print(f"✅ Dynamic credentials generated:")
            print(f"   Username: {creds['username']}")
            print(f"   Lease duration: {creds['lease_duration']}s")
            print(f"   Lease ID: {creds['lease_id']}")
            
            return creds
        
        except Exception as e:
            print(f"❌ Error generating credentials: {e}")
            raise
    
    def renew_token(self, increment: int = 3600):
        """Renew Vault token untuk extend TTL"""
        print(f"🔄 Renewing token (increment: {increment}s)...")
        
        try:
            response = self.client.auth.token.renew_self(increment=increment)
            print(f"✅ Token renewed. New TTL: {response['auth']['lease_duration']}s")
            return response
        except Exception as e:
            print(f"❌ Error renewing token: {e}")
            raise
    
    def revoke_lease(self, lease_id: str):
        """Revoke lease (misalnya untuk dynamic credentials)"""
        print(f"🗑️  Revoking lease: {lease_id}")
        
        try:
            self.client.sys.revoke_lease(lease_id)
            print(f"✅ Lease revoked")
        except Exception as e:
            print(f"❌ Error revoking lease: {e}")
            raise


def main():
    """Main application logic"""
    
    # Configuration
    VAULT_ADDR = os.getenv("VAULT_ADDR", "http://localhost:8200")
    AUTH_METHOD = os.getenv("VAULT_AUTH_METHOD", "approle")
    
    print("=" * 60)
    print("🚀 Vault Python Demo Application")
    print("=" * 60)
    print(f"Vault Address: {VAULT_ADDR}")
    print(f"Auth Method: {AUTH_METHOD}")
    print()
    
    try:
        # Initialize Vault client
        vault = VaultClient(VAULT_ADDR, AUTH_METHOD)
        
        # Example 1: Fetch static secrets
        print("\n" + "=" * 60)
        print("Example 1: Static Secrets (KV v2)")
        print("=" * 60)
        
        config = vault.get_secret("myapp/config")
        
        if config:
            print("\n📦 Application Config:")
            for key, value in config.items():
                # Mask sensitive values di output
                display_value = value if key not in ["password", "api_key", "token"] else "***"
                print(f"   {key}: {display_value}")
        
        # Example 2: Dynamic database credentials
        print("\n" + "=" * 60)
        print("Example 2: Dynamic Database Credentials")
        print("=" * 60)
        
        # Uncomment jika sudah setup database secrets engine
        # db_creds = vault.get_database_credentials("myapp-role")
        # print(f"\n🗄️  Database Connection String:")
        # print(f"   postgresql://{db_creds['username']}:***@postgres:5432/mydb")
        
        # Example 3: Token renewal
        print("\n" + "=" * 60)
        print("Example 3: Token Renewal")
        print("=" * 60)
        
        vault.renew_token(increment=3600)
        
        # Simulate application runtime
        print("\n" + "=" * 60)
        print("✅ Application running...")
        print("Press Ctrl+C to exit")
        print("=" * 60)
        
        while True:
            time.sleep(10)
            # Periodic token renewal (every 10 minutes)
            # vault.renew_token()
    
    except KeyboardInterrupt:
        print("\n\n👋 Shutting down gracefully...")
        sys.exit(0)
    
    except Exception as e:
        print(f"\n❌ Fatal error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
