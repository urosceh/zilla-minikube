# Protokol fer poređenja infrastrukturnih modela

Ovaj dokument beleži metodologiju koja treba da se koristi za finalne
eksperimente i analizu u diplomskom radu.

## Opseg poređenja

Primarno poređenje obuhvata modele `iso` i `shared`.

Modeli `hybrid` i `grouped` su sekundarni eksperimenti i nisu deo iste
rang-liste. `grouped` kombinuje ISO, hybrid i shared podmodele na jednom
Minikube profilu i koristi se kao samostalan test mešovitog, opterećenog
okruženja.

Postojeći rezultati:

- `results/20260907T173544Z-iso`
- `results/20260909T065319Z-hybrid`
- `results/20260909T071020Z-shared`
- `results/20260909T090907Z-grouped`

predstavljaju pilot-testove. Ne treba ih koristiti kao finalno međusobno
poređenje jer nemaju identične faze, broj VU-ova i raspon think time-a.

## Šta znači „fer” u ovom eksperimentu

Poređenje je test fiksnog infrastrukturnog troška:

- ISO, hybrid i shared profili imaju 3 CPU, 4096 MiB RAM-a i disk od 20 GiB;
- odgovarajući tipovi komponenti imaju iste Kubernetes requests/limits;
- svaki izabrani tenant dobija isti k6 raspored i 10 VU-ova;
- svi modeli koriste isti scenario i isti request mix;
- faze testa i think time su identični;
- svaki VU koristi jednog korisnika, prijavljuje se jednom tokom warmup-a i
  ponovo se prijavljuje samo posle odgovora `401`;
- aplikacioni podaci se resetuju pre svakog merenja;
- svaki model se meri najmanje tri puta.

Broj tenant-a i ukupan broj podova nisu jednaki. To je namerna posledica
arhitekture:

- ISO: 1 tenant (`arm`);
- shared: 10 tenant-a (`amazon`, `amd`, `apple`, `azure`, `google`, `meta`,
  `netflix`, `nvidia`, `paypal`, `reddit`).

Zbog toga je jednako **opterećenje po tenant-u**, ali ne i ukupno opterećenje
klastera: ISO ima 10, a shared 100 istovremenih VU-ova. Rezultate treba
opisati kao poređenje kapaciteta i efikasnosti predviđenih topologija na
serverima iste veličine. Ne treba tvrditi da se meri čista razlika
arhitektura pod identičnim ukupnim saobraćajem.

## Resursni budžet

Za steady-state Deployment-e i exportere, bez monitoring namespace-a i
završenih init/migration Job-ova:

| Model | CPU requests | RAM requests | Objašnjenje |
|---|---:|---:|---|
| ISO | 900m | 1536 Mi | 1 BE + FE + nginx + PG + Redis + 2 exportera |
| Hybrid | 1400m | 2048 Mi | 3 BE + deljeni FE/nginx/PG/Redis + 2 exportera |
| Shared | 900m | 1536 Mi | 1 deljeni BE + FE + nginx + PG + Redis + 2 exportera |
| Grouped | 3200m | 5120 Mi | ISO + hybrid + shared podmodeli zajedno |

Hybrid ima 500m više CPU requests i 512 Mi više RAM requests od ISO/shared
modela zbog dva dodatna backend poda. Zato ne treba pisati da modeli imaju
jednake ukupne zahteve. Ispravna formulacija je:

> Modeli koriste jednak infrastrukturni kapacitet i standardizovane veličine
> odgovarajućih komponenti, dok se broj komponenti razlikuje kao posledica
> arhitekture.

Grouped zahteva približno 3200m CPU i 5120 Mi samo za aplikacione Deployment-e
i exportere. Njegov profil zato koristi 4 CPU i 6144 MiB kako bi ostao prostor
za monitoring i kube-system. Zbog različitog kapaciteta ostaje izdvojen iz
primarnog fixed-cost poređenja.

U starim pilot rezultatima `metrics-summary.json -> resource_requests` može
obuhvatiti i završene migration/tenant-init Job podove koje kube-state-metrics
još uvek vidi. Aktuelni exporter filtrira samo podove u `Running` fazi. Za
stvarnu potrošnju koristiti `cpu_cores` i `memory_working_set_bytes`.

## Kanonski parametri finalnog testa

Za svaki finalni run koristiti:

```text
WARMUP_SECONDS=60
STEADY_SECONDS=180
COOLDOWN_SECONDS=30
VUS_PER_TENANT=10
THINK_TIME_MIN_SECONDS=2
THINK_TIME_MAX_SECONDS=4
```

Kanonske vrednosti se nalaze u `experiments/fair-comparison.env`. Finalni
runner ih učitava direktno, tako da pojedinačni run-ovi ne mogu slučajno
dobiti različite override vrednosti.

Warmup prvih 30 sekundi podiže opterećenje od 0 do 10 VU-ova po tenant-u, a
narednih 30 sekundi drži svih 10 VU-ova radi zagrevanja. Think time se za
svaku iteraciju bira uniformno između 2 i 4 sekunde.

Kanonski tenant skup je takođe definisan u tom fajlu: jedan ISO tenant i
deset shared tenant-a. Ručni override promenljive `TENANTS` nije deo finalnog
protokola.

## Automatski postupak merenja

Primarno poređenje pokrenuti komandom:

```bash
./scripts/run-fair-comparison.sh primary
```

Runner automatski:

- pokreće prvo `iso`, pa `shared`, svaki po tri puta;
- između svaka dva eksperimenta traži `y/n` potvrdu, tako da se završeni run
  može pregledati i screenshot-ovati u Grafani pre početka sledećeg;
- zaustavlja ostale Minikube profile pre svakog merenja;
- proverava da se image lock nije promenio;
- radi purge i seed modela, a opterećuje kanonski tenant skup;
- prosleđuje identične parametre svakom run-u;
- upisuje protocol, batch i repetition podatke u `parameters.json`;
- proverava parametre, image-e i k6 exit code pre računanja statistike;
- generiše comparison JSON i CSV za svaki model.

Aktivni Minikube profil se ne restartuje između ponavljanja istog modela.
Ručna pauza na potvrdi razdvaja k6 pikove, dok bi restart unosio cold-start
efekte i praznine u scrape-ovanju. Profil ostaje dostupan dok se Grafana
pregleda, a pri prelasku na drugi model runner ga zaustavlja radi izolacije
host resursa.

Sekundarni testovi se pokreću odvojeno:

```bash
./scripts/run-fair-comparison.sh hybrid
./scripts/run-fair-comparison.sh grouped
```

## Ručni postupak merenja

Za svaki od primarnih modela:

```bash
./scripts/purge-model.sh <model>
./scripts/seed-model.sh <model>

TENANTS=<kanonski-tenant-skup-za-model> \
WARMUP_SECONDS=60 \
STEADY_SECONDS=180 \
COOLDOWN_SECONDS=30 \
VUS_PER_TENANT=10 \
THINK_TIME_MIN_SECONDS=2 \
THINK_TIME_MAX_SECONDS=4 \
./scripts/run-experiment.sh <model>
```

Ove tri komande ponoviti tri puta za svaki model. Jedno pokretanje
`run-experiment.sh` predstavlja samo jedan run; skripta sama ne izvršava tri
ponavljanja.

Tokom merenja treba:

- držati aktivnim samo Minikube profil koji se trenutno meri;
- izbegavati druge zahtevne procese na host računaru;
- koristiti isti image lock i k6 verziju;
- sačekati da workload i monitoring budu Ready;
- ne menjati manifests, tenant set ili parametre između ponavljanja.

Za hybrid i grouped koristiti iste faze, VU-ove i think time i takođe tri
ponavljanja, ali rezultate analizirati odvojeno.

## Obrada i prikaz rezultata

Za tri ponavljanja pojedinačnog modela koristiti:

```bash
python3 experiments/compare_runs.py \
  results/<run-1> \
  results/<run-2> \
  results/<run-3> \
  --output-prefix results/<model>-three-run-comparison
```

U finalnoj analizi prikazati najmanje:

- srednju vrednost i sample standard deviation;
- ukupan RPS po serveru;
- RPS po tenant-u;
- k6 end-to-end p50/p95/p99 latenciju;
- Prometheus serversku p50/p95/p99 latenciju;
- error rate i k6 checks;
- CPU i memory working set;
- CPU throttling;
- broj podova i tenant-a.

Ukupan RPS govori o kapacitetu servera, dok RPS po tenant-u omogućava
razumnije poređenje korisničkog iskustva između modela sa različitim brojem
tenant-a. Memoriju i CPU treba prikazati zajedno sa brojem podova, a ne kao
izolovane vrednosti.

Shared pilot-run je imao primetan CPU throttling. Ako se isto ponovi u finalnim
run-ovima, to mora biti navedeno kao uticaj konfigurisanog CPU limita, a ne
pripisano isključivo multi-tenant arhitekturi.

