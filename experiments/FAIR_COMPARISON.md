# Protokol fer poređenja infrastrukturnih modela

Ovaj dokument beleži metodologiju koja treba da se koristi za finalne
eksperimente i analizu u diplomskom radu.

## Opseg poređenja

Primarno poređenje obuhvata modele `iso`, `hybrid` i `shared`.

Model `grouped` nije deo iste rang-liste. On kombinuje ISO, hybrid i shared
podmodele na jednom Minikube profilu i koristi se kao samostalan test
mešovitog, opterećenog okruženja.

Postojeći rezultati:

- `results/20260907T173544Z-iso`
- `results/20260909T065319Z-hybrid`
- `results/20260909T071020Z-shared`
- `results/20260909T090907Z-grouped`

predstavljaju pilot-testove. Ne treba ih koristiti kao finalno međusobno
poređenje jer nemaju identične `steady_seconds` i `think_time_seconds`
parametre.

## Šta znači „fer” u ovom eksperimentu

Poređenje je test fiksnog infrastrukturnog troška:

- ISO, hybrid i shared profili imaju 3 CPU, 4096 MiB RAM-a i disk od 20 GiB;
- odgovarajući tipovi komponenti imaju iste Kubernetes requests/limits;
- svaki tenant dobija isti k6 raspored i isti broj VU-ova;
- svi modeli koriste isti scenario i isti request mix;
- faze testa i think time su identični;
- aplikacioni podaci se resetuju pre svakog merenja;
- svaki model se meri najmanje tri puta.

Broj tenant-a i ukupan broj podova nisu jednaki. To je namerna posledica
arhitekture:

- ISO: 1 tenant;
- hybrid: 3 tenant-a;
- shared: 15 tenant-a.

Zbog toga je jednako **opterećenje po tenant-u**, a ne ukupno opterećenje
klastera. Rezultate treba opisati kao poređenje kapaciteta i efikasnosti
različitih topologija na serverima iste veličine. Ne treba tvrditi da se meri
čista razlika arhitektura pod identičnim ukupnim saobraćajem.

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
WARMUP_SECONDS=30
STEADY_SECONDS=120
COOLDOWN_SECONDS=30
VUS_PER_TENANT=2
THINK_TIME_SECONDS=0.25
```

Kanonske vrednosti se nalaze u `experiments/fair-comparison.env`. Finalni
runner ih učitava direktno, tako da pojedinačni run-ovi ne mogu slučajno
dobiti različite override vrednosti.

Ne koristiti `TENANTS`, odnosno testirati pun tenant set svakog modela.
Parametre navesti eksplicitno u komandi čak i kada odgovaraju podrazumevanim
vrednostima, kako bi protokol bio očigledan i lako ponovljiv.

## Automatski postupak merenja

Primarno poređenje pokrenuti komandom:

```bash
./scripts/run-fair-comparison.sh primary
```

Runner automatski:

- pokreće `iso`, `hybrid` i `shared` po tri puta;
- rotira redosled modela između ponavljanja;
- zaustavlja ostale Minikube profile pre svakog merenja;
- proverava da se image lock nije promenio;
- radi purge i seed kompletnog tenant seta;
- prosleđuje identične parametre svakom run-u;
- upisuje protocol, batch i repetition podatke u `parameters.json`;
- proverava parametre, image-e i k6 exit code pre računanja statistike;
- generiše comparison JSON i CSV za svaki model.

Grouped test se pokreće isključivo odvojeno:

```bash
./scripts/run-fair-comparison.sh grouped
```

## Ručni postupak merenja

Za svaki od modela `iso`, `hybrid` i `shared`:

```bash
./scripts/purge-model.sh <model>
./scripts/seed-model.sh <model>

WARMUP_SECONDS=30 \
STEADY_SECONDS=120 \
COOLDOWN_SECONDS=30 \
VUS_PER_TENANT=2 \
THINK_TIME_SECONDS=0.25 \
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

Za grouped, ako se prikazuje kao dodatni eksperiment, koristiti iste parametre
i takođe tri ponavljanja, ali rezultate analizirati odvojeno.

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

