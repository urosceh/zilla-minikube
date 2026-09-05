# Isolated Model - Kubernetes Architecture (Mermaid Diagrams)

## 1. 🏗️ Kompletan Sistem Dizajn (Complete System Design)

```mermaid
graph TB
    subgraph K8s ["Kubernetes Namespace"]
        subgraph ext["EXTERNAL ACCESS LAYER"]
            lb["⚙️ LoadBalancer Service<br/>nginx-bff:80<br/>Ekspozicija ka svetu"]
        end
        
        subgraph app["APPLICATION LAYER"]
            front["🖥️ Deployment: zilla-frontend<br/>Port: 8080<br/>React/Typescript"]
            back["⚡ Deployment: zilla-backend<br/>Port: 3000<br/>Express/Typescript API"]
            nginx_config["📋 ConfigMap: nginx-config<br/>Nginx Routing Konfiguracija"]
        end
        
        subgraph data["DATA & CACHE LAYER"]
            db["🗄️ Deployment: PostgreSQL<br/>Port: 5450<br/>Database: zilla<br/>Glavna Baza Podataka"]
            redis["💾 Deployment: Redis<br/>Port: 6379<br/>Distribuirani Kes"]
            pvc["📦 PersistentVolumeClaim<br/>postgres-pvc<br/>Storage: 1Gi"]
        end
        
        subgraph setup["MIGRATIONS & INIT"]
            job["🔄 Job: zilla-migrations<br/>Liquibase<br/>Izvrsavanje DB Migracija"]
            init1["⏳ Init Container<br/>wait-for-postgres<br/>Cekanje na DB"]
            init2["⏳ Init Container<br/>wait-for-redis<br/>Cekanje na Redis"]
        end
        
        subgraph sec["SECRETS MANAGEMENT"]
            sec_pg["🔐 Secret: postgres-secret<br/>DB_USERNAME, DB_PASSWORD"]
            sec_redis["🔐 Secret: redis-secret<br/>REDIS_PASSWORD"]
        end
    end
    
    User["👤 Korisnik/Pretraživač<br/>Client Side"]
    
    User -->|HTTP/HTTPS| lb
    lb -->|/api/*| back
    lb -->|/*| front
    front -->|REST Pozivi| back
    back -->|SQL Upiti| db
    back -->|Kesiranje| redis
    back --> init1
    back --> init2
    db --> pvc
    job -->|Migrira Schema| db
    back -.->|Koristi| sec_pg
    redis -.->|Koristi| sec_redis
    db -.->|Koristi| sec_pg
    nginx_config -->|Konfiguracija| lb
```mermaid

## 2. 📊 Data Flow - Tok Podataka (Kako Radi)

```mermaid
graph LR
    subgraph client["CLIENT SIDE"]
        browser["🌐 Web Pretraživač<br/>React SPA"]
    end
    
    subgraph lb_layer["LOAD BALANCER"]
        nginx["🔀 Nginx BFF<br/>Port 80<br/>Reverse Proxy"]
    end
    
    subgraph app_layer["APPLICATION"]
        fe["📱 Frontend<br/>Port 8080<br/>UI Serviranje"]
        be["⚙️ Backend<br/>Port 3000<br/>API Obrada"]
    end
    
    subgraph data_layer["DATA LAYER"]
        pg["🗄️ PostgreSQL<br/>Port 5450<br/>Relaciona BP"]
        redis["💾 Redis<br/>Port 6379<br/>Kes"]
    end
    
    browser -->|HTTP Zahtev na :80| nginx
    nginx -->|GET / <br/>Staticni Fajlovi| fe
    nginx -->|GET /api/* <br/>API Zahtevi| be
    
    fe -->|AXIOS na :80<br/>za /api/*| nginx
    
    be -->|SELECT/INSERT<br/>SQL Upiti| pg
    be -->|SET/GET<br/>Kesiranje| redis
    
    browser -.->|Prikazuje| fe
```

---

## 3. 🚀 Deployment Workflow - Proces Razvoja

```mermaid
graph TD
    start["🎯 Pocni Razvoj<br/>Izolovanog Okruzenja"] --> step1["📝 Pripremi Tenant Ime<br/>npr: amazon, google, etc"]
    
    step1 --> step2["🔨 deploy_tenant.sh<br/>my-tenant"]
    
    step2 --> step2_1["✓ Provjeri minikube prim<br/>Klaster"]
    step2_1 --> step2_2["✓ Kreiraj K8s Namespace<br/>kubectl create namespace"]
    step2_2 --> step2_3["🔐 Generiraj Tajne<br/>Random Credentiale<br/>DB_USERNAME: 20 chars<br/>DB_PASSWORD: 20 chars<br/>REDIS_PASSWORD: 20 chars"]
    step2_3 --> step2_4["📄 Kreiraj secrets.yaml<br/>Base64 Enkodiranje"]
    step2_4 --> step2_5["⚙️ Primjeni Kubernetes Manifest<br/>kubectl apply secrets<br/>kubectl apply dsp.yaml"]
    
    step2_5 --> step3["✅ Okruzenje Kreirano"]
    
    step3 --> check{"Trebas li<br/>Test Podatke?"}
    
    check -->|DA| step4["📊 seed_iso.sh<br/>namespace count"]
    step4 --> step4_1["👤 Kreiraj Admin Korisnika<br/>insert.admin.script.js"]
    step4_1 --> step4_2["👥 Kreiraj Batch Korisnika<br/>seed.users.script.js<br/>Default: 20 Korisnika"]
    step4_2 --> step4_3["💾 Snimi u CSV<br/>./passwords/tenant-users.csv"]
    step4_3 --> check2
    
    check -->|NE| ready["✅ Spreman za Upotrebu!"]
    check2{"Trebas li<br/>Testove?"}
    
    check2 -->|DA| step5["⚡ k6-test.sh<br/>tenant projects-count type"]
    step5 --> step5_1["🗑️ Purge Baza<br/>Obriši Postojeće Podatke"]
    step5_1 --> step5_2["📥 Seed Testni Podaci<br/>Pripremi Test Okruzenje"]
    step5_2 --> step5_3["🌉 Port Forwarding<br/>localhost:3000 →<br/>pod/backend:3000"]
    step5_3 --> step5_4["🧪 Pokretanje k6 Testa<br/>Load/Stress/Soak"]
    step5_4 --> step5_5["📈 Generisanje Izvjestaja<br/>Performanse i Rezultati"]
    step5_5 --> ready
    
    ready --> end["🎊 Spreman za Upotrebu!"]
    
    style start fill:#c8e6c9
    style end fill:#c8e6c9
    style ready fill:#ffecb3
    style check fill:#b3e5fc
    style check2 fill:#b3e5fc
```

---

## 4. 🔄 Service Dependencies - Zavisnosti Servisa

```mermaid
graph TB
    subgraph init["INIT CONTAINERS<br/>Inicijalni Kontejneri"]
        wait_pg["⏳ wait-for-postgres<br/>Ceka: postgres:5450"]
        wait_redis["⏳ wait-for-redis<br/>Ceka: redis:6379"]
    end
    
    subgraph main["MAIN APPLICATION<br/>Glavna Aplikacija"]
        backend["⚙️ zilla-backend<br/>Port 3000<br/>Zavisi od init kontejnera"]
    end
    
    subgraph services["SERVICES<br/>Servisi"]
        svc_pg["🗄️ Service: postgres<br/>Port 5450"]
        svc_redis["💾 Service: redis<br/>Port 6379"]
        svc_fe["📱 Service: zilla-frontend<br/>Port 8080"]
        svc_be["⚙️ Service: zilla-backend<br/>Port 3000"]
        svc_lb["🔀 Service: nginx-bff<br/>Port 80"]
    end
    
    subgraph deploy["DEPLOYMENTS<br/>Rasporedjivanja"]
        dep_pg["🗄️ Deployment: PostgreSQL<br/>1 Replika"]
        dep_redis["💾 Deployment: Redis<br/>1 Replika"]
        dep_be["⚙️ Deployment: Backend<br/>1 Replika"]
        dep_fe["📱 Deployment: Frontend<br/>1 Replika"]
        dep_nginx["🔀 Deployment: Nginx BFF<br/>1 Replika"]
    end
    
    subgraph jobs["JOBS<br/>Poslovi"]
        mig["🔄 Job: zilla-migrations<br/>Liquibase Update"]
    end
    
    wait_pg -->|Provjera Konekcije| svc_pg
    wait_redis -->|Provjera Konekcije| svc_redis
    backend -->|Zavisi od| wait_pg
    backend -->|Zavisi od| wait_redis
    
    backend -->|Ekspozicija| svc_be
    dep_be -->|Kreira| backend
    
    svc_pg -->|Ekspozicija| dep_pg
    svc_redis -->|Ekspozicija| dep_redis
    svc_fe -->|Ekspozicija| dep_fe
    svc_be -->|Ekspozicija| dep_be
    svc_lb -->|Proxy| svc_fe
    svc_lb -->|Proxy| svc_be
    
    mig -->|Migrira u| dep_pg
    
    dep_nginx -->|Kreira| svc_lb
    
    style init fill:#ffccbc
    style main fill:#c8e6c9
    style services fill:#b3e5fc
    style deploy fill:#f8bbd0
    style jobs fill:#fff9c4
```

---

## 5. 🗄️ Database Architecture - Arhitektura Baze Podataka

```mermaid
graph TB
    subgraph storage["STORAGE LAYER<br/>Sloj Skladistenja"]
        pvc["📦 PersistentVolumeClaim<br/>postgres-pvc<br/>Kapacitet: 1Gi<br/>AccessMode: ReadWriteOnce"]
        volume["💿 Physical Volume<br/>Host Storage<br>/var/lib/postgresql/data"]
    end
    
    subgraph db_layer["DATABASE LAYER<br/>Sloj Baze Podataka"]
        pod["🐘 PostgreSQL Pod<br/>postgres:14-alpine"]
        container["📦 Kontejner: postgres<br/>Port: 5450<br/>Proces: postgres server"]
        datadir["📂 Montaza: /var/lib/postgresql/data<br/>Odmah na PVC"]
    end
    
    subgraph config["CONFIGURATION<br/>Konfiguracija"]
        secret["🔐 Secret: postgres-secret<br/>DB_USERNAME<br/>DB_PASSWORD"]
        env["🌍 Environment Varijable<br/>POSTGRES_DB=zilla<br/>PGPORT=5450"]
    end
    
    subgraph svc["SERVICE LAYER<br/>Sloj Servisa"]
        service["🌐 Service: postgres<br/>Type: ClusterIP<br/>Port 5450 → 5450"]
    end
    
    subgraph clients["CLIENTS<br/>Klijenti"]
        backend["⚙️ Backend App<br/>JDBC Connection"]
        migrations["🔄 Migrations Job<br/>Liquibase Update"]
    end
    
    pvc -->|Montazna Tocka| volume
    pod -->|Koristi| datadir
    datadir -->|Montazna Tocka| pvc
    container -->|Radi u| pod
    secret -->|Credentiale| container
    env -->|Konfiguracija| container
    service -->|Ekspozicija| pod
    backend -->|Konekcija na| service
    migrations -->|Konekcija na| service
    
    style storage fill:#e8f5e9
    style db_layer fill:#c8e6c9
    style config fill:#fff9c4
    style svc fill:#b3e5fc
    style clients fill:#f3e5f5
```

---

## 6. 🔐 Security & Secrets - Sigurnost i Tajne

```mermaid
graph TB
    subgraph gen["SECRET GENERATION<br/>Generisanje Tajni"]
        script["📝 deploy_tenant.sh<br/>Script za Generisanje"]
        gen_user["🎲 Generiraj DB_USERNAME<br/>20 Random Alfanumerica"]
        gen_pass["🎲 Generiraj DB_PASSWORD<br/>20 Random Alfanumerica"]
        gen_redis["🎲 Generiraj REDIS_PASSWORD<br/>20 Random Alfanumerica"]
    end
    
    subgraph encode["ENCODING<br/>Kodiranje"]
        b64_user["📊 Base64 Enkodiranje<br/>DB_USERNAME"]
        b64_pass["📊 Base64 Enkodiranje<br/>DB_PASSWORD"]
        b64_redis["📊 Base64 Enkodiranje<br/>REDIS_PASSWORD"]
    end
    
    subgraph storage["KUBERNETES SECRETS<br/>K8s Tajne"]
        secret_pg["🔐 Secret: postgres-secret<br/>Key: DB_USERNAME (b64)<br/>Key: DB_PASSWORD (b64)<br/>Type: Opaque"]
        secret_redis["🔐 Secret: redis-secret<br/>Key: REDIS_PASSWORD (b64)<br/>Type: Opaque"]
    end
    
    subgraph usage["USAGE IN PODS<br/>Koriscenje u Pod-ima"]
        back_use["⚙️ Backend Deployment<br/>valueFrom: secretKeyRef<br/>name: postgres-secret"]
        db_use["🗄️ PostgreSQL Deployment<br/>valueFrom: secretKeyRef<br/>name: postgres-secret"]
        redis_use["💾 Redis Deployment<br/>valueFrom: secretKeyRef<br/>name: redis-secret"]
        mig_use["🔄 Migrations Job<br/>valueFrom: secretKeyRef<br/>name: postgres-secret"]
    end
    
    script --> gen_user
    script --> gen_pass
    script --> gen_redis
    
    gen_user --> b64_user
    gen_pass --> b64_pass
    gen_redis --> b64_redis
    
    b64_user --> secret_pg
    b64_pass --> secret_pg
    b64_redis --> secret_redis
    
    secret_pg --> back_use
    secret_pg --> db_use
    secret_pg --> mig_use
    secret_redis --> redis_use
    
    style gen fill:#ffe0b2
    style encode fill:#ffccbc
    style storage fill:#fff9c4
    style usage fill:#f3e5f5
```

---

## 7. 🧪 Testing Workflow - Testiranje Radnog Toka

```mermaid
graph TD
    start["🎯 k6-test.sh<br/>tenant projects-count type"] --> purge["🗑️ PURGE FASE<br/>Brisanje Podataka"]
    
    purge --> purge1["./purge_iso.sh tenant<br/>Obriši sve iz Baze"]
    purge1 --> purge2["Reset Database Status<br/>Spremi za nove podatke"]
    
    purge2 --> seed["📥 SEED FASE<br/>Punjenje Test Podaka"]
    
    seed --> seed1["./seed_iso.sh tenant USERS_COUNT<br/>USERS_COUNT = projects × 10"]
    seed1 --> seed2["Kreiraj Admin Korisnika<br/>admin@tenant.dne.com"]
    seed2 --> seed3["Kreiraj Batch Korisnika<br/>Default: 20 Korisnika"]
    seed3 --> seed4["Spremi Credentiale u CSV"]
    
    seed4 --> forward["🌉 PORT FORWARDING"]
    
    forward --> forward1["Provjera Port 3000<br/>Kill ako je zauzet"]
    forward1 --> forward2["kubectl port-forward<br/>localhost:3000 → pod:3000"]
    forward2 --> forward3["Cekanje na Readiness<br/>Health Check: /api/health"]
    
    forward3 --> test["🧪 K6 TESTING FASE"]
    
    test --> test_type{"Tip Testa?"}
    
    test_type -->|LOAD| load["📈 Load Test<br/>Simulacija Normal Opterecenja<br/>k6-load-test.js"]
    test_type -->|STRESS| stress["⚠️ Stress Test<br/>Simulacija Peak Opterecenja<br/>Raste sa Vremenom<br/>k6-stress-test.js"]
    test_type -->|SOAK| soak["🔄 Soak Test<br/>Dugotrajno Testiranje<br/>Trazenje Memory Leak-a<br/>k6-soak-test.js"]
    
    load --> metrics["📊 Prikupi Metrike<br/>Response Time<br/>Throughput<br/>Error Rate"]
    stress --> metrics
    soak --> metrics
    
    metrics --> results["📈 RESULTATI"]
    
    results --> results1["Generiši Izvjestaj<br/>JSON Format"]
    results1 --> results2["Snimi Log Fajlove<br/>./output/"]
    results2 --> results3["Analiziraj Performanse<br/>Bottleneck Identifikacija"]
    
    results3 --> cleanup["🧹 CLEANUP FASE"]
    
    cleanup --> cleanup1["Kill Port Forwarding<br/>Oslobodi Port 3000"]
    cleanup1 --> end["✅ Test Kompletan"]
    
    style start fill:#c8e6c9
    style purge fill:#ffccbc
    style seed fill:#ffe0b2
    style forward fill:#b3e5fc
    style test fill:#f8bbd0
    style test_type fill:#fff9c4
    style load fill:#ffebee
    style stress fill:#fbe9e7
    style soak fill:#ede7f6
    style results fill:#e0f2f1
    style cleanup fill:#f3e5f5
    style end fill:#c8e6c9
```

---

## 8. 📋 ConfigMap: Nginx Routing - Nginx Usmjeravanje

```mermaid
graph LR
    subgraph req["INCOMING REQUESTS<br/>Dolazni Zahtjevi"]
        req_root["GET / (Root)"]
        req_api["GET /api/*"]
        req_static["GET /static/*"]
    end
    
    subgraph nginx["NGINX BFF<br/>Port 80<br/>Reverse Proxy"]
        config["📋 ConfigMap<br/>nginx-config<br/>default.conf"]
        rules["Routing Pravila<br/>location /api/<br/>location /"]
    end
    
    subgraph routes["ROUTING DESTINATIONS<br/>Odrediste Usmjeravanja"]
        fe_route["Frontend Ruta<br/>proxy_pass<br/>http://zilla-frontend:8080/"]
        be_route["Backend Ruta<br/>proxy_pass<br/>http://zilla-backend:3000/api/"]
    end
    
    subgraph dest["DESTINATIONS<br/>Finalne Odrediste"]
        frontend["📱 zilla-frontend:8080<br/>React SPA<br/>Staticni Fajlovi"]
        backend["⚙️ zilla-backend:3000<br/>Express API<br/>Biznis Logika"]
    end
    
    subgraph headers["PROXY HEADERS<br/>Proxy Zaglavlja"]
        h1["Host: $host"]
        h2["X-Real-IP: $remote_addr"]
        h3["X-Forwarded-For: $proxy_add_x_forwarded_for"]
        h4["X-Forwarded-Proto: $scheme"]
    end
    
    req_root --> config
    req_api --> config
    req_static --> config
    
    config --> rules
    rules -->|Matcha /api/*| be_route
    rules -->|Matcha /*| fe_route
    
    be_route -->|Prosljedjuje| backend
    fe_route -->|Prosljedjuje| frontend
    
    h1 --> be_route
    h2 --> be_route
    h3 --> be_route
    h4 --> be_route
    
    h1 --> fe_route
    h2 --> fe_route
    h3 --> fe_route
    h4 --> fe_route
    
    style req fill:#e3f2fd
    style nginx fill:#fff3e0
    style routes fill:#f3e5f5
    style dest fill:#e8f5e9
    style headers fill:#fff9c4
```

---

## 9. 🎯 Quick Reference: Entiteti i Uloge

```mermaid
graph TB
    subgraph entities["KUBERNETES ENTITIES<br/>K8s Entiteti"]
        subgraph deploy["DEPLOYMENTS<br/>Rasporedjivanja"]
            d1["PostgreSQL"]
            d2["Redis"]
            d3["zilla-backend"]
            d4["zilla-frontend"]
            d5["nginx-bff"]
        end
        
        subgraph services["SERVICES<br/>Servisi"]
            s1["postgres - ClusterIP:5450<br/>Interni pristup"]
            s2["redis - ClusterIP:6379<br/>Interni pristup"]
            s3["zilla-backend - ClusterIP:3000<br/>Interni pristup"]
            s4["zilla-frontend - LoadBalancer:8080<br/>Spoljasnji pristup"]
            s5["nginx-bff - LoadBalancer:80<br/>Spoljasnji pristup"]
        end
        
        subgraph config["CONFIGURATION<br/>Konfiguracija"]
            c1["postgres-secret<br/>DB Credentiale"]
            c2["redis-secret<br/>Cache Credentiale"]
            c3["nginx-config<br/>Routing Rules"]
        end
        
        subgraph storage["STORAGE<br/>Skladistenje"]
            st1["postgres-pvc - 1Gi<br/>Database Persistence"]
        end
        
        subgraph jobs["JOBS<br/>Poslovi"]
            j1["zilla-migrations<br/>Liquibase DB Updates"]
        end
    end
    
    d1 --> s1
    d2 --> s2
    d3 --> s3
    d4 --> s4
    d5 --> s5
    
    d3 -.->|Koristi| c1
    d1 -.->|Koristi| c1
    d2 -.->|Koristi| c2
    d5 -.->|Koristi| c3
    
    d1 -.->|Koristi| st1
    j1 -.->|Ažurira| d1
    
    style entities fill:#f0f4c3
    style deploy fill:#c8e6c9
    style services fill:#b3e5fc
    style config fill:#fff9c4
    style storage fill:#e8f5e9
    style jobs fill:#ffccbc
```

---

## 📚 Legenda i Objasnjenja (Legend and Explanations)

| Simbol | Znacenje | Objasnjenje |
|--------|----------|-----------|
| 🗄️ | PostgreSQL | Relacijska baza podataka za skladistenje struktuiranih podataka |
| 💾 | Redis | In-memory cache za brz pristup i sesijsko skladistenje |
| ⚙️ | Backend | Node.js/Express API servic sa poslovnom logikom |
| 📱 | Frontend | React SPA aplikacija za korisnički interfejs |
| 🔀 | Nginx BFF | Reverse proxy i backend-for-frontend za routing |
| 🌐 | LoadBalancer | Servis za spoljasnji pristup iz interneta |
| 🔐 | Secret | Zastitena K8s konfiguracija sa credentialima |
| 📋 | ConfigMap | Javna K8s konfiguracija bez tajnih podataka |
| 📦 | PVC | Persistent Volume Claim za trajno skladistenje |
| 🔄 | Job | Jednom izvršavan posao - migracije |
| ⏳ | Init Container | Inicijalni kontejner - provjera zavisnosti |

---

## 🚀 Brz Pokretanje (Quick Start)

```bash
# 1. Kreiraj novi tenant namespace
./isolated/deploy_tenant.sh my-tenant

# 2. Punjenje test podacima (20 korisnika default)
./isolated/seed_iso.sh my-tenant 50

# 3. Pokretanje load testa
./isolated/k6-test.sh my-tenant 20 load

# 4. Provjera stanja deployment-a
kubectl get all -n my-tenant

# 5. Brisanje okruzenja
kubectl delete namespace my-tenant
```

---

**Kreirano za**: Zilla Minikube Isolated Model  
**Arhitektura**: Multitenant K8s sa po-tenant izolacijom  
**Teststiranje**: k6 load testing za performanse  
**Jezik**: Srpski (latinica) sa engleskim terministima
