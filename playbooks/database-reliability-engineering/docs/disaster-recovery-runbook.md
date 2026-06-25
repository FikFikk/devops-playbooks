# =============================================================================
# DISASTER RECOVERY RUNBOOK
# Database Reliability Engineering — Production PostgreSQL Cluster
# =============================================================================
# Dokumen ini adalah panduan step-by-step untuk kondisi darurat.
# JANGAN mengandalkan ingatan — ikuti langkah-langkah ini secara berurutan.
# Update dokumen ini setiap kali prosedur berubah!
# =============================================================================

# CONTACT SHEET (Update sesuai tim Anda!)
# =========================================
# On-Call DBA        : database-oncall@perusahaan.com | +62-8xx-xxxx-xxxx
# Engineering Lead   : lead-eng@perusahaan.com
# CTO (escalation)   : cto@perusahaan.com
# AWS Support        : https://console.aws.amazon.com/support/

# SEVERITY LEVELS
# ================
# SEV-1 (CRITICAL): Database tidak bisa diakses, data loss risk, semua layanan down
# SEV-2 (HIGH)    : Performa sangat buruk, beberapa layanan terdampak
# SEV-3 (MEDIUM)  : Peringatan threshold, tidak ada dampak user langsung

# =============================================================================
# SKENARIO 1: PRIMARY NODE FAILURE (Auto-Handled oleh Patroni)
# Estimasi waktu: 2-5 menit (otomatis)
# =============================================================================

skenario_1_primary_failure() {
    # Gejala: Application error "connection refused", alert "PostgreSQLDown"
    
    # Step 1: Verifikasi alert (30 detik)
    echo "=== VERIFIKASI STATUS CLUSTER ==="
    patronictl -c /etc/patroni/patroni.yml list
    
    # Output yang diharapkan setelah auto-failover:
    # db-replica-01 | Leader  | running  ← baru dipromosikan
    # db-primary-01 | Replica | stopped  ← yang failed
    # db-replica-02 | Replica | running
    
    # Step 2: Monitor proses failover
    watch -n 2 'patronictl -c /etc/patroni/patroni.yml list'
    
    # Step 3: Setelah failover selesai, verifikasi aplikasi berfungsi
    psql -h haproxy-vip -p 5000 -U app_user myapp -c "SELECT now();"
    
    # Step 4: Investigasi node yang gagal
    ssh db-primary-01 'sudo journalctl -u patroni -n 100'
    ssh db-primary-01 'sudo journalctl -u postgresql -n 100'
    
    # Step 5: Jika node bisa diperbaiki, bisa rejoin cluster
    # (Patroni akan otomatis sync data via pg_basebackup atau pg_rewind)
    ssh db-primary-01 'sudo systemctl start patroni'
    
    # Setelah berhasil start, monitor apakah berhasil join sebagai replica
    patronictl -c /etc/patroni/patroni.yml list
}

# =============================================================================
# SKENARIO 2: FAILOVER MANUAL (Planned Maintenance)
# Estimasi waktu: 5-10 menit
# =============================================================================

skenario_2_planned_failover() {
    # Gunakan ini saat: upgrade OS primary, hardware maintenance, dll
    
    # Step 1: Pastikan replika tidak lag
    patronictl -c /etc/patroni/patroni.yml list
    # Pastikan 'Lag in MB' = 0 sebelum failover!
    
    # Step 2: Jadwalkan maintenance window dan notifikasi tim
    echo "Maintenance window dimulai: $(date)"
    
    # Step 3: Lakukan failover ke node yang diinginkan
    patronictl -c /etc/patroni/patroni.yml failover production-db \
        --master db-primary-01 \
        --candidate db-replica-01 \
        --force
    
    # Step 4: Verifikasi failover berhasil
    patronictl -c /etc/patroni/patroni.yml list
    psql -h haproxy-vip -p 5000 -c "SELECT inet_server_addr();"
    
    # Step 5: Lakukan maintenance di node lama (sekarang sudah jadi replica)
    # ...maintenance tasks...
    
    # Step 6: Jika ingin failback ke node original
    # (opsional — tidak selalu diperlukan)
    patronictl -c /etc/patroni/patroni.yml failover production-db \
        --master db-replica-01 \
        --candidate db-primary-01 \
        --scheduled "$(date -d '+10 minutes' '+%Y-%m-%dT%H:%M')"
}

# =============================================================================
# SKENARIO 3: POINT-IN-TIME RECOVERY (Data Korrupsi atau Accidental Delete)
# Estimasi waktu: 30-60 menit
# SEV-1 jika terjadi di production
# =============================================================================

skenario_3_pitr() {
    # SITUASI: DBA / bug aplikasi tidak sengaja menghapus data penting
    # Misal: "DROP TABLE orders;" atau "DELETE FROM users WHERE 1=1"
    
    # ⚠️  PENTING: Catat waktu exact kejadian insiden!
    INCIDENT_TIME="2024-06-15 14:35:00+07"
    RESTORE_TARGET="2024-06-15 14:34:00+07"   # 1 menit sebelum insiden
    
    # Step 1: SEGERA hentikan semua write ke database yang affected!
    # (Isolasi dari aplikasi agar tidak ada write baru yang menimpa)
    # Caranya: ubah connection string aplikasi ke database readonly,
    # atau scale down aplikasi sementara
    
    # Step 2: Cek backup yang tersedia
    pgbackrest --stanza=production info
    
    # Step 3: Siapkan server restore (JANGAN restore ke production langsung!)
    # Gunakan server staging atau instance baru
    TARGET_PATH="/var/lib/postgresql/16/pitr-restore"
    mkdir -p "$TARGET_PATH"
    chown postgres:postgres "$TARGET_PATH"
    
    # Step 4: Lakukan PITR ke waktu tepat sebelum insiden
    sudo -u postgres pgbackrest --stanza=production restore \
        --pg1-path="$TARGET_PATH" \
        --type=time \
        --target="$RESTORE_TARGET" \
        --target-action=promote \
        --delta
    
    # Step 5: Start instance PostgreSQL dari data yang di-restore
    sudo -u postgres pg_ctl \
        -D "$TARGET_PATH" \
        -o "-p 5433" \
        start
    
    # Step 6: Verifikasi data sudah benar
    psql -p 5433 -U postgres -c "SELECT count(*) FROM orders;"
    psql -p 5433 -U postgres -c "
        SELECT max(created_at) FROM orders;  -- Pastikan data ada sampai sebelum insiden"
    
    # Step 7: Extract data yang perlu di-restore
    pg_dump -p 5433 -U postgres \
        --table=orders \
        --data-only \
        myapp > /tmp/orders_recovery.sql
    
    # Step 8: Import ke database production
    psql -h haproxy-vip -p 5000 -U postgres myapp < /tmp/orders_recovery.sql
    
    # Step 9: Verifikasi data di production
    psql -h haproxy-vip -p 5000 -U postgres myapp \
        -c "SELECT count(*) FROM orders;"
    
    # Step 10: Bersihkan restore environment
    sudo -u postgres pg_ctl -D "$TARGET_PATH" stop
    rm -rf "$TARGET_PATH"
    
    echo "Recovery selesai. Waktu total: $(($(date +%s) - START_TIME)) detik"
}

# =============================================================================
# SKENARIO 4: FULL DATACENTER FAILURE (Rebuild dari Backup)
# Estimasi waktu: 60-120 menit
# SEV-1 — Eskalasi ke CTO
# =============================================================================

skenario_4_datacenter_failure() {
    # SITUASI: Seluruh datacenter/region AWS tidak tersedia
    # Tujuan: Setup cluster baru di region lain dari backup

    DR_REGION="ap-southeast-3"
    STANZA="production"
    
    # Step 1: Konfirmasi datacenter failure (bukan hanya network blip)
    # Cek AWS Service Health Dashboard
    # Hubungi AWS Support jika perlu
    
    # Step 2: Aktifkan DR environment di region sekunder
    cd /root/devops-playbooks/playbooks/database-reliability-engineering/terraform
    
    # Arahkan terraform ke DR region
    export AWS_DEFAULT_REGION="$DR_REGION"
    
    terraform workspace select dr || terraform workspace new dr
    terraform apply -var="primary_region=$DR_REGION" -auto-approve
    
    # Step 3: Setup nodes baru di DR region
    # (Gunakan Ansible atau script otomatis)
    ansible-playbook -i inventory/dr setup-db-cluster.yml
    
    # Step 4: Restore dari backup S3 (yang sudah di-replikasi ke DR region)
    DR_S3_BUCKET="db-backup-dr-production-ACCOUNT_ID"
    
    # Update pgbackrest config untuk pointing ke DR bucket
    sed -i "s/repo1-s3-bucket=.*/repo1-s3-bucket=$DR_S3_BUCKET/" \
        /etc/pgbackrest/pgbackrest.conf
    sed -i "s/repo1-s3-endpoint=.*/repo1-s3-endpoint=s3.$DR_REGION.amazonaws.com/" \
        /etc/pgbackrest/pgbackrest.conf
    sed -i "s/repo1-s3-region=.*/repo1-s3-region=$DR_REGION/" \
        /etc/pgbackrest/pgbackrest.conf
    
    # Step 5: Restore backup terbaru
    sudo -u postgres pgbackrest --stanza="$STANZA" restore
    
    # Step 6: Start Patroni cluster di DR
    systemctl start patroni
    
    # Tunggu cluster siap
    sleep 30
    patronictl -c /etc/patroni/patroni.yml list
    
    # Step 7: Update DNS untuk mengarahkan aplikasi ke DR
    # (Gunakan Route53 atau update /etc/hosts sementara)
    
    # Step 8: Verifikasi layanan berfungsi
    psql -h db-primary-dr -p 5000 -U postgres -c "SELECT count(*) FROM pg_tables;"
    
    # Step 9: Notifikasi tim bahwa DR aktif
    echo "FAILOVER COMPLETED. DR cluster aktif di $DR_REGION"
    # Kirim ke Slack/PagerDuty
}

# =============================================================================
# POST-INCIDENT CHECKLIST
# =============================================================================

post_incident_checklist() {
    echo "=== POST-INCIDENT CHECKLIST ==="
    
    # 1. Verifikasi cluster sehat
    patronictl -c /etc/patroni/patroni.yml list
    
    # 2. Verifikasi replikasi berjalan normal
    psql -U postgres -c "SELECT * FROM pg_stat_replication;"
    
    # 3. Verifikasi backup masih berjalan
    pgbackrest --stanza=production check
    pgbackrest --stanza=production info
    
    # 4. Verifikasi monitoring berfungsi
    curl -s http://localhost:9187/metrics | grep -c "pg_up"
    
    # 5. Buat backup full segera setelah recovery
    sudo -u postgres pgbackrest --stanza=production backup --type=full
    
    # 6. Dokumentasikan insiden (Incident Report)
    # - Waktu deteksi
    # - Waktu response
    # - Root cause
    # - Timeline tindakan
    # - Dampak
    # - Action items untuk mencegah terulang
    
    # 7. Update runbook jika ada perubahan prosedur
}
