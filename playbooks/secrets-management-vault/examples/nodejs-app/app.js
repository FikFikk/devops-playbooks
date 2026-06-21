// Node.js Vault Integration Example
// Dependencies: node-vault (npm install node-vault)

const vault = require('node-vault');

class VaultClient {
  constructor(vaultAddr = process.env.VAULT_ADDR || 'http://localhost:8200') {
    this.vaultAddr = vaultAddr;
    this.authMethod = process.env.VAULT_AUTH_METHOD || 'approle';
    this.client = null;
  }

  async authenticate() {
    const options = {
      apiVersion: 'v1',
      endpoint: this.vaultAddr,
    };

    if (this.authMethod === 'approle') {
      // AppRole authentication
      const roleId = process.env.VAULT_ROLE_ID;
      const secretId = process.env.VAULT_SECRET_ID;

      if (!roleId || !secretId) {
        throw new Error('VAULT_ROLE_ID dan VAULT_SECRET_ID harus diset');
      }

      console.log('🔐 Authenticating ke Vault menggunakan AppRole...');
      
      const tempClient = vault(options);
      const result = await tempClient.approleLogin({
        role_id: roleId,
        secret_id: secretId,
      });

      options.token = result.auth.client_token;
      this.client = vault(options);

      console.log(`✅ Authentication berhasil! Token TTL: ${result.auth.lease_duration}s`);
    } else if (this.authMethod === 'kubernetes') {
      // Kubernetes authentication
      const fs = require('fs');
      const jwt = fs.readFileSync('/var/run/secrets/kubernetes.io/serviceaccount/token', 'utf8');
      const role = process.env.VAULT_ROLE || 'myapp';

      console.log(`🔐 Authenticating ke Vault menggunakan Kubernetes auth (role: ${role})...`);

      const tempClient = vault(options);
      const result = await tempClient.kubernetesLogin({
        role: role,
        jwt: jwt,
      });

      options.token = result.auth.client_token;
      this.client = vault(options);

      console.log(`✅ Authentication berhasil! Token TTL: ${result.auth.lease_duration}s`);
    } else if (this.authMethod === 'token') {
      // Development: direct token
      const token = process.env.VAULT_TOKEN;
      if (!token) {
        throw new Error('VAULT_TOKEN harus diset');
      }

      options.token = token;
      this.client = vault(options);
      console.log('✅ Menggunakan VAULT_TOKEN');
    } else {
      throw new Error(`Auth method tidak didukung: ${this.authMethod}`);
    }
  }

  async getSecret(path, mountPoint = 'secret') {
    console.log(`📖 Reading secret: ${mountPoint}/${path}`);

    try {
      const result = await this.client.read(`${mountPoint}/data/${path}`);
      const data = result.data.data;
      const metadata = result.data.metadata;

      console.log(`✅ Secret retrieved (version ${metadata.version})`);
      return data;
    } catch (err) {
      if (err.response && err.response.statusCode === 404) {
        console.log(`❌ Secret tidak ditemukan: ${path}`);
        return null;
      }
      throw err;
    }
  }

  async getDatabaseCredentials(role) {
    console.log(`🔑 Generating dynamic database credentials untuk role: ${role}`);

    try {
      const result = await this.client.read(`database/creds/${role}`);
      
      const creds = {
        username: result.data.username,
        password: result.data.password,
        leaseId: result.lease_id,
        leaseDuration: result.lease_duration,
      };

      console.log('✅ Dynamic credentials generated:');
      console.log(`   Username: ${creds.username}`);
      console.log(`   Lease duration: ${creds.leaseDuration}s`);
      console.log(`   Lease ID: ${creds.leaseId}`);

      return creds;
    } catch (err) {
      console.log(`❌ Error generating credentials: ${err.message}`);
      throw err;
    }
  }

  async renewToken(increment = 3600) {
    console.log(`🔄 Renewing token (increment: ${increment}s)...`);

    try {
      const result = await this.client.tokenRenewSelf({ increment });
      console.log(`✅ Token renewed. New TTL: ${result.auth.lease_duration}s`);
      return result;
    } catch (err) {
      console.log(`❌ Error renewing token: ${err.message}`);
      throw err;
    }
  }

  async revokeLease(leaseId) {
    console.log(`🗑️  Revoking lease: ${leaseId}`);

    try {
      await this.client.revoke({ lease_id: leaseId });
      console.log('✅ Lease revoked');
    } catch (err) {
      console.log(`❌ Error revoking lease: ${err.message}`);
      throw err;
    }
  }
}

async function main() {
  console.log('='.repeat(60));
  console.log('🚀 Vault Node.js Demo Application');
  console.log('='.repeat(60));
  console.log(`Vault Address: ${process.env.VAULT_ADDR || 'http://localhost:8200'}`);
  console.log(`Auth Method: ${process.env.VAULT_AUTH_METHOD || 'approle'}`);
  console.log();

  try {
    // Initialize Vault client
    const vaultClient = new VaultClient();
    await vaultClient.authenticate();

    // Example 1: Fetch static secrets
    console.log('\n' + '='.repeat(60));
    console.log('Example 1: Static Secrets (KV v2)');
    console.log('='.repeat(60));

    const config = await vaultClient.getSecret('myapp/config');

    if (config) {
      console.log('\n📦 Application Config:');
      for (const [key, value] of Object.entries(config)) {
        const displayValue = ['password', 'api_key', 'token'].includes(key) ? '***' : value;
        console.log(`   ${key}: ${displayValue}`);
      }
    }

    // Example 2: Dynamic database credentials
    console.log('\n' + '='.repeat(60));
    console.log('Example 2: Dynamic Database Credentials');
    console.log('='.repeat(60));

    // Uncomment jika sudah setup database secrets engine
    // const dbCreds = await vaultClient.getDatabaseCredentials('myapp-role');
    // console.log('\n🗄️  Database Connection String:');
    // console.log(`   postgresql://${dbCreds.username}:***@postgres:5432/mydb`);

    // Example 3: Token renewal
    console.log('\n' + '='.repeat(60));
    console.log('Example 3: Token Renewal');
    console.log('='.repeat(60));

    await vaultClient.renewToken(3600);

    // Simulate application runtime
    console.log('\n' + '='.repeat(60));
    console.log('✅ Application running...');
    console.log('Press Ctrl+C to exit');
    console.log('='.repeat(60));

    // Keep alive
    setInterval(async () => {
      // Periodic token renewal (every 10 minutes)
      // await vaultClient.renewToken();
    }, 600000);

  } catch (err) {
    console.error(`\n❌ Fatal error: ${err.message}`);
    process.exit(1);
  }
}

// Handle graceful shutdown
process.on('SIGINT', () => {
  console.log('\n\n👋 Shutting down gracefully...');
  process.exit(0);
});

process.on('SIGTERM', () => {
  console.log('\n\n👋 Shutting down gracefully...');
  process.exit(0);
});

if (require.main === module) {
  main();
}

module.exports = { VaultClient };
