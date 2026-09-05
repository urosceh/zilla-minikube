# 🎯 Isolated Model - Brz Pregled (Quick Overview)

## Sta je Isolated Model?

Isolated model je Kubernetes arhitektura gdje **svaki tenant ima svesvoju izoliranu okruzenja** sa:
- ✅ Sopstvenim Namespace-om
- ✅ Sopstvenom PostgreSQL bazom
- ✅ Sopstvenom Redis cache-om
- ✅ Sopstvenom Backend i Frontend-om
- ✅ Sopstvenim Nginx BFF-om

**Prednost**: Potpuna izolacija - svaki tenant je **potpuno nezavisan**!

---

## 📊 Kubernetes Entiteti (Sta se Deploy-a)

```
PO TENANT NAMESPACE:
├─ DEPLOYMENTS (5):
│  ├─ PostgreSQL (Baza Podataka) - Port 5450
│  ├─ Redis (Cache) - Port 6379
│  ├─ zilla-backend (API) - Port 3000
│  ├─ zilla-frontend (UI) - Port 8080
│  └─ nginx-bff (Reverse Proxy) - Port 80
│
├─ SERVICES (5):
│  ├─ postgres (ClusterIP) - Interni pristup
│  ├─ redis (ClusterIP) - Interni pristup
│  ├─ zilla-backend (ClusterIP) - Interni pristup
│  ├─ zilla-frontend (LoadBalancer) - Spoljasnji pristup
│  └─ nginx-bff (LoadBalancer) - Spoljasnji pristup
│
├─ CONFIGMAPS (1):
│  └─ nginx-config - Routing pravila
│
├─ SECRETS (2):
│  ├─ postgres-secret - DB credentiale
│  └─ redis-secret - Cache credentiale
│
├─ STORAGE (1):
│  └─ postgres-pvc - 1Gi za bazu
│
└─ JOBS (1):
   └─ zilla-migrations - Liquibase DB update
```

---

## 🔄 Kako Radi - Data Flow

```
Korisnik sa Pretraživaca
    ↓
    HTTP na Port 80
    ↓
[Nginx BFF] (Reverse Proxy)
    ↙              ↘
GET /api/*     GET /*
    ↓              ↓
[Backend]      [Frontend]
Port 3000      Port 8080
    ↓
[PostgreSQL]  [Redis]
5450          6379
```

**Tok zahtjeva**:
1. Korisnik ide na `http://localhost` (Nginx na portu 80)
2. Nginx rutira `/api/*` → Backend na portu 3000
3. Nginx rutira `/*` → Frontend na portu 8080
4. Backend komunicira sa PostgreSQL i Redis
5. Frontend šalje AJAX zahtjeve Backend-u

---

## 🚀 Operacije - Kako Se Koristi

### 1️⃣ Deploy Nova Tenant Okruzenja

```bash
./isolated/deploy_tenant.sh my-tenant
```

**Sta se desava**:
- ✓ Kreiraj K8s namespace `my-tenant`
- ✓ Generiši random credentiale (20 karaktera)
- ✓ Kreiraj secrets.yaml sa Base64 enkodirane tajne
- ✓ Primjeni dsp.yaml manifest
- ✓ Pokreni sve kontejnere

**Rezultat**: Kompletna okruzenja sprema za upotrebu! 🎉

---

### 2️⃣ Punjenje Test Podacima (Seeding)

```bash
./isolated/seed_iso.sh my-tenant 50
```

**Sta se desava**:
- ✓ Kreiraj 1 Admin korisnika (admin@my-tenant.dne.com)
- ✓ Kreiraj 50 regular korisnika sa random credentialima
- ✓ Snimi sve kredencijale u `./passwords/my-tenant-users.csv`

**CSV Format**:
```
email,password
user1@my-tenant.dne.com,randomPassword123
user2@my-tenant.dne.com,randomPassword456
...
```

---

### 3️⃣ Pokretanje Load Testova

```bash
./isolated/k6-test.sh my-tenant 20 load
```

**Parametri**:
- `my-tenant` - Namespace gdje testiramo
- `20` - Broj projekata
- `load` - Tip testa (load/stress/soak)

**Proces**:
1. **PURGE**: Obriši sve podatke iz baze
2. **SEED**: Kreiraj testne podatke (20 projekata × 10 = 200 korisnika)
3. **PORT FORWARD**: localhost:3000 → pod:3000
4. **TEST**: Pokreni k6 test skriptu
5. **CLEANUP**: Oslobodi port

**Tipovi Testova**:
- `load` - Normalno opterecenje (simulira regular korisnije)
- `stress` - Rastuce opterecenje (do max kapaciteta)
- `soak` - Dugotrajna tst sa konstantnim opterecenjem

**Rezultati**: U `./isolated/output/` folderu
```
output/
└─ load-15-2025-10-26-11-31-05/
   ├─ k6-test-amazon.log
   ├─ k6-test-google.log
   └─ RESULTS_SUMMARY.md
```

---

## 🔐 Sigurnost - Tajne

**Kako se Tajne Generisuju**:

```bash
# 1. Generiši random alfanumeriku
DB_USERNAME_RAW="aBcDeF1234567890123"  # 20 karaktera

# 2. Base64 enkodiranje
DB_USERNAME_B64=$(printf "%s" "$DB_USERNAME_RAW" | base64)
# Rezultat: YUJjRGVGMTIzNDU2Nzg5MDEyMw==

# 3. Snimi u secrets.yaml
# apiVersion: v1
# kind: Secret
# data:
#   DB_USERNAME: YUJjRGVGMTIzNDU2Nzg5MDEyMw==

# 4. Primjeni u K8s
kubectl apply -f secrets.yaml -n my-tenant
```

**Gdje se Koriste**:
- Backend - Konektovanje na PostgreSQL
- PostgreSQL - Autentifikacija
- Redis - Zastiteni pristup
- Migrations - DB update access

---

## 🎯 Kubernetes Resource Requirements

```yaml
Backend:
  CPU Requests: 0.25
  Memory Requests: 192Mi
  Memory Limit: 256Mi
  # Ocekuje da se koristi do 256MB RAM-a max

PostgreSQL:
  Storage: 1Gi
  Access Mode: ReadWriteOnce
  # Baza se ne moze pristupati sa vise pod-a odjednom

Redis:
  Default: Best-effort
  # Memorija dostupna po potrebi
```

---

## 📱 Init Containers - Cekanje na Zavisnosti

Prije nego sto Backend pocne sa radom, moraju biti dostupni:

```
Backend Pod → Inicijalizacija
  ├─ Init Container 1: wait-for-postgres
  │  └─ Ceka: postgres:5450 dostupan
  │     (Koristi: nc command, timeout 30 sekundi)
  │
  └─ Init Container 2: wait-for-redis
     └─ Ceka: redis:6379 dostupan
        (Koristi: nc command, timeout 30 sekundi)

Tek onda...
  ↓
Backend Container pocinje sa radom
```

**Ako zavisnosti nisu dostupne**: Pod ostaje u `PendingInitialize` stanju i ne radi!

---

## 🗄️ Database Architecture

```
PostgreSQL:
├─ Host: postgres (DNS ime)
├─ Port: 5450 (non-standard za isolation)
├─ Database: zilla
├─ Credentiale: Iz secrets
│  ├─ Username: random 20 chars
│  └─ Password: random 20 chars
│
└─ Storage:
   ├─ PVC: postgres-pvc
   ├─ Size: 1Gi
   └─ Mount: /var/lib/postgresql/data
```

**Migracije - Kako se Izvršavaju**:

```
Liquibase Job pokrenut pri Deploy-u
  ↓
Konektuje na PostgreSQL
  ↓
Citajucidbchangelog.xml
  ↓
Izvršava SQL migracije
  ↓
Kreira database schema
  ↓
Backend je spreman za upotrebu
```

---

## 🧪 Testing Infrastruktura

**K6 Skripte**:
```
./k6/
├─ k6-load-test.js
│  └─ Normalno opterecenje sa gradulanim porascajem
│
├─ k6-stress-test.js
│  └─ Do granice kapaciteta - trazenje bottleneck-a
│
└─ k6-soak-test.js
   └─ Dugotrajna provjera - trazenje memory leak-a
```

**Metriki koje se Prikupljaju**:
- Response Time (p50, p95, p99)
- Throughput (zahtjeva po sekundi)
- Error Rate (neuspjesni zahtjevi)
- Memory Usage
- CPU Usage
- Connection Pool Status

---

## 📁 File Structure - Struktura Fajlova

```
isolated/
├─ deploy_tenant.sh      # Deploy nova okruzenja
├─ seed_iso.sh          # Punjenje test podacima
├─ purge_iso.sh         # Brisanje test podacima
├─ k6-test.sh           # Pokretanje testova
│
├─ dsp.yaml             # Kubernetes manifest
├─ secrets.yaml         # Template za secrets (demo)
│
├─ iso/                 # Primjer deployed okruzenja
│  └─ secrets.yaml      # Auto-generated credentials
│
├─ k6/                  # Test skripte
│  ├─ k6-load-test.js
│  ├─ k6-stress-test.js
│  └─ k6-soak-test.js
│
└─ passwords/           # Generisane user credentials
   ├─ iso-users.csv
   └─ ...
```

---

## 🎓 Primjer Kompletan Flow

```bash
# 1. Deploy nova okruzenja za "amazon" tenant
$ ./isolated/deploy_tenant.sh amazon
✓ Namespace "amazon" kreiran
✓ Secrets generirani
✓ Deployment pokrenut
✓ PostgreSQL pokrenut
✓ Redis pokrenut
✓ Backend pokrenut
✓ Frontend pokrenut
✓ Nginx BFF pokrenut

# 2. Provjera stanja
$ kubectl get all -n amazon
NAME                                      READY   STATUS
pod/postgres-xxxxx                        1/1     Running
pod/redis-xxxxx                           1/1     Running
pod/zilla-backend-xxxxx                   1/1     Running
pod/zilla-frontend-xxxxx                  1/1     Running
pod/nginx-bff-xxxxx                       1/1     Running
pod/zilla-migrations-xxxxx                0/1     Completed

# 3. Punjenje sa test podacima
$ ./isolated/seed_iso.sh amazon 30
✓ Admin korisnik kreiran
✓ 30 regularnih korisnika kreirano
✓ Credentiale snimleni u ./passwords/amazon-users.csv

# 4. Pokretanje load testa
$ ./isolated/k6-test.sh amazon 15 load
✓ Baza purged
✓ Test podaci seeded
✓ Port forwarding aktiviran
✓ k6 test pokrenut - čeka rezultate...

# 5. Rezultati dostupni u:
./isolated/output/load-15-2025-10-26-11-31-05/RESULTS_SUMMARY.md

# 6. Brisanje okruzenja kada je gotovo
$ kubectl delete namespace amazon
✓ Namespace "amazon" obrisan
```

---

## 💡 Best Practices

1. **Uvijek kreiraj odvojeno okruzenje za testiranje**
   - Ne testiras u production tenant-ima!

2. **Snimi credentiale sigurno**
   - CSV fajlovi su lokalni - štititi ih kao tajne

3. **Koristi razlicite tenant imena**
   - `my-tenant-dev`, `my-tenant-staging`, `my-tenant-prod`

4. **Redovito ocisti stara test okruzenja**
   - `kubectl delete namespace old-test-tenant`

5. **Prati test rezultate**
   - RESULTS_SUMMARY.md fajl pokazuje bottleneck-e

---

## ❓ FAQ

**P: Mogu li testirati vise tenanta odjednom?**
- A: DA! Svaki tenant je u svom namespace-u - bez konflikta

**P: Sta se desava ako Backend ne moze da se konektor na PostgreSQL?**
- A: Pod ostaje u PendingInitialize stanju - Init Container ceka 30 sekundi pa retry-a

**P: Gdje se cuvaju podaci iz baze?**
- A: U PVC -> Host storage (/var/lib/postgresql/data)

**P: Mogu li skalirati replike?**
- A: DA - pero svaki tenant ima samo 1 repliku po defaultu

**P: Kako obrijem okruzenje sa svim podacima?**
- A: `kubectl delete namespace my-tenant` - sve ide u cos!

---

## 📚 Dokumentacija

- Kompletne Mermaid diagrame vidi u: `ISOLATED_ARCHITECTURE.md`
- k6 test skripte: `isolated/k6/`
- Deploy skripte: `isolated/deploy_tenant.sh`, `isolated/seed_iso.sh`
- Kubernetes manifest: `isolated/dsp.yaml`

---

**Odgovorno od**: Team Zilla  
**Kreirano**: 2025-10-26  
**Jezik**: Srpski (latinica) sa engleskim terminima  
**Format**: Markdown + Mermaid Diagrams

