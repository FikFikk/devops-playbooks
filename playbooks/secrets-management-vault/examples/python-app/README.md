# Python Vault Integration Example

## Local Development

```bash
# Install dependencies
pip install -r requirements.txt

# Setup Vault (dev mode)
docker run -d --name vault-dev -p 8200:8200 \
  -e VAULT_DEV_ROOT_TOKEN_ID=root \
  hashicorp/vault:1.17

export VAULT_ADDR='http://localhost:8200'
export VAULT_TOKEN='root'

# Setup secrets
vault secrets enable -path=secret kv-v2
vault kv put secret/myapp/config \
  db_password="dev-password" \
  api_key="dev-api-key"

# Setup AppRole
vault auth enable approle
vault policy write myapp-policy - <<EOF
path "secret/data/myapp/*" {
  capabilities = ["read"]
}
EOF

vault write auth/approle/role/myapp \
  token_policies="myapp-policy" \
  token_ttl=1h

# Get credentials
export VAULT_ROLE_ID=$(vault read -field=role_id auth/approle/role/myapp/role-id)
export VAULT_SECRET_ID=$(vault write -field=secret_id -f auth/approle/role/myapp/secret-id)

# Run app
python app.py
```

## Kubernetes Deployment

```bash
# Build & push image
docker build -t myapp:latest .
docker push myapp:latest

# Deploy
kubectl apply -f k8s-deployment.yaml
```
