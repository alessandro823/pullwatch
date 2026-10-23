# Pullwatch — versie-overzicht (welke repo's lopen achter)

Datum: 2026-10-23
Status: gebruiker gaf akkoord om zonder verdere vragen te bouwen

## Waarom

De gebruiker wil in één oogopslag zien welke gevolgde repo's achterlopen op taal- en frameworkversie.

## Doelen

- Knop **Versies…** in het menu opent een eigen venster (zoals Geschiedenis).
- Check draait **alleen op knopdruk**; resultaat wordt bewaard en getoond met tijdstip.
- Per repo: taal (niveau 1) en runtimes/frameworks (niveau 2), elk met status **Actueel / Achter / EOL** (of **Onbekend**).

## Niet-doelen

- Losse packages/dependencies op "achter" checken (niveau 3).
- Achtergrond-checks of meldingen.

## Wat de gebruiker besliste

- Niveau 1 + 2.
- Alleen gevolgde repo's.
- Alleen op knopdruk.
- Indeling B: per repo gegroepeerd, onderdelen eronder, slechtste status bovenaan.
- **Achter** alleen bij een nieuwere major/minor, niet bij een gemiste patch.

## Ontwerp

### Gevolgde repo's

Per pollbaar account `listRepos()`, gefilterd op `account.watch(for:)` met minstens één vinkje (PR's, Tags of Completed). Zo tellen ook repo's mee die via de standaard voor nieuwe repo's gevolgd worden.

### Bestanden lezen (provider)

Twee nieuwe methodes op `PRProvider`:

- `filePaths(in:)` — alle bestandspaden op de default branch, in één aanvraag.
  GitHub `GET /repos/{repo}/git/trees/HEAD?recursive=1`; Azure DevOps `GET {project}/_apis/git/repositories/{repo}/items?scopePath=/&recursionLevel=Full`.
  Lege repo (GitHub 409, Azure 404) → lege lijst.
- `fileContent(in:path:)` — inhoud als tekst. GitHub `contents/{path}` met raw-Accept; Azure `items?path=…&includeContent=true`.

### Herkenning

Alleen bestanden buiten `node_modules`, `vendor`, `.git`, `bin`, `obj`, `dist`, `build`, max. 50 per repo:

| Bestand | Onderdeel | Bron van de versie |
|---|---|---|
| `go.mod` | Go | `go 1.x` |
| `*.csproj`, `*.fsproj`, `Directory.Build.props` | .NET | `TargetFramework(s)` `netX.Y` (geen netstandard/net4x) |
| `package.json` | Node | `engines.node` |
| `package.json` | Angular, React, Vue, Next.js, Nuxt | `@angular/core`, `react`, `vue`, `next`, `nuxt` in (dev)dependencies |
| `.nvmrc`, `.node-version` | Node | eerste getal |
| `pyproject.toml` | Python | `requires-python` |
| `.python-version` | Python | inhoud |
| `Dockerfile*` | Docker: image | `FROM image:tag` voor bekende images (node, golang, python, dotnet, alpine, debian, ubuntu, nginx, postgres, redis, eclipse-temurin, rust, php, ruby) |

Versiespec → eerste `getal(.getal)*` (`^17.2.0` → `17.2.0`, `>=3.11` → `3.11`, `20-alpine` → `20`). Niet te lezen (variabelen, `lts/*`, `latest`) → overgeslagen.
Komt een onderdeel meerdere keren voor in een repo, dan telt de **oudste** versie; de bronbestanden staan in de tooltip.

### Laatste versie

endoflife.date API v1 (`/api/v1/products/{product}`), één aanvraag per product per check (gecachet binnen de check).
Releases met `releaseDate` in de toekomst tellen niet. De gevonden versie hoort bij de release met de langste naam waar de versie gelijk aan is of mee begint (`1.25.3` → `1.25`, `8.0` → `8`).

- release `isEol` → **EOL**
- release is niet de nieuwste uitgebrachte release → **Achter**
- anders → **Actueel**
- geen passende release of product onbereikbaar → **Onbekend**

### Opslag

`versions.json` in Application Support (`JSONFileStore<VersionReport>`).

### UI (indeling B)

Venster "Versies". Bovenin "Gecheckt {tijd}" en knop **Opnieuw checken** (tijdens check: voortgang "x/y repo's"). Lijst per repo, slechtste status eerst, dan alfabetisch: gekleurde stip + reponaam, daaronder per onderdeel `label versie → laatste` met pill. Repo zonder herkende onderdelen: "Niets herkend". Repo met fout: foutmelding in rood. Leeg (nooit gecheckt): uitleg + knop.

Kleuren: Actueel groen, Achter oranje, EOL rood, Onbekend grijs.

## Calls van Claude

- Hele boom scannen in plaats van alleen root (anders mist .NET bijna altijd, csproj staat in submappen).
- Oudste versie per onderdeel telt.
- "Nieuwste" = nieuwste uitgebrachte release, ook als die geen LTS is.
- Repo's per account na elkaar; accounts parallel. Fout bij één repo stopt de rest niet.
- Knop in het menu naast Geschiedenis.

## Uitbreiding 2026-10-23: CVE-check en kopiëren

Gebruiker vroeg: CVE-check via OSV.dev en een kopieerknop per repo.

- Packages met exacte versie uit `go.mod` (requires, zonder `v`), `package-lock.json` (v1–3), `PackageReference`/`PackageVersion` (.csproj/.fsproj/Directory.*.props), `requirements*.txt` (alleen `==`), `poetry.lock`, `uv.lock`. Geen yarn/pnpm (Claude's call).
- Eén `POST /v1/querybatch` voor alle unieke packages over alle repo's (per 1000), daarna `GET /v1/vulns/{id}` per unieke id (8 tegelijk) voor samenvatting, ernst (`database_specific.severity`), CVE-alias en fix-versies (GIT-ranges genegeerd).
- Ids die elkaars alias zijn voor hetzelfde package: alleen de alfabetisch eerste (GHSA wint van GO, Claude's call).
- Fix-versie: laagste "fixed" na de huidige versie.
- OSV onbereikbaar: versies blijven, repo met packages toont "CVE-check mislukt".
- Sorteren: een repo met kwetsbaarheden weegt als EOL, daarna meeste kwetsbaarheden (Claude's call). Stip rood.
- UI: uitklapbare regel "N kwetsbaarheden (x critical, …)" met ernst-pill, CVE-link naar osv.dev, `package versie → fix`, samenvatting. Zoeken ook op package en CVE/OSV-id.
- Kopieerknop per repo: repo, onderdelen met status, kwetsbaarheden met ernst, package, fix en link, als platte tekst.

## Uitbreiding 2026-10-23: dagelijks automatisch

Gebruiker koos: check vanzelf, melding bij nieuwe CVE's (vervangt "alleen op knopdruk").

- `AppConfig.autoVersionCheck` (standaard aan), schakelaar onder Instellingen → Algemeen.
- Elke 24 uur na de vorige check (handmatig telt mee), gecontroleerd in de poll-lus.
- Melding alleen voor CVE's (id + package) die er bij de vorige check voor die repo nog niet waren. Geen melding zonder vorige check, voor nieuw gevolgde repo's, of als de vorige CVE-check of scan van die repo mislukte (Claude's call: geen stortvloed).
- Tot 3 losse meldingen (klik opent osv.dev), anders één samenvatting.
- Automatische check waarbij elke repo een fout gaf: resultaat weggooien, opnieuw na 1 uur.

## Uitbreiding 2026-10-23: PHP

Aanleiding: `acme/php-api` (PHP) werd niet herkend.

- `composer.json`: `require.php` → PHP; `laravel/framework` → Laravel; `symfony/framework-bundle`/`http-kernel`/`console` → Symfony.
- `composer.lock` (`packages` + `packages-dev`, zonder `v`, geen `dev-*`) → OSV-ecosysteem Packagist.
- Framework-versie uit de lockfile gaat voor het minimum uit het manifest (`^7.2` was 7.4.8 → anders vals EOL). Geldt ook voor npm-frameworks via `package-lock.json`.
- Docker: onbekende imagenaam met bekende naam vóór het eerste "-" (bv. `php-fpm-alpine-custom`) telt als dat image (Claude's call; kan een enkele "Onbekend" opleveren bij bv. `node-exporter`).

## Uitbreiding 2026-10-23: Rust en Dockerfile-fixes

Aanleiding: `acme/rust-service` (Rust) werd niet herkend.

- Rust uit `rust-toolchain`/`rust-toolchain.toml` (`channel`), anders `rust-version` uit de root-`Cargo.toml` (minimum; toolchain gaat voor).
- `Cargo.lock`: alleen packages met `source = "registry+…"` → OSV-ecosysteem crates.io.
- Dockerfile: `@sha256:…`-digest weghalen vóór het splitsen op ":" (miste `postgres:18.6@sha256:…`); `ARG NAAM=waarde` invullen in `FROM` (`rust:${RUST_VERSION}-slim`).

## Correctie 2026-10-23: minimum vs. vastgezet

Aanleiding: `acme/go-tool` toonde Go 1.21 (EOL) terwijl de module go 1.27.2 gebruikt, en Node 20 (`engines` `>=20`) terwijl Docker Node 24 draait.

- `go.mod` in een map die een andere go.mod via `replace … => ./pad` aanwijst telt niet (gevendorde dependency; zijn `go`-regel is een minimum).
- `DetectedVersion.isMinimum` voor `engines.node`, composer `php`, `requires-python`, `rust-version`. Valt weg als hetzelfde product in de repo ergens niet-minimum voorkomt (Docker, .nvmrc, toolchain, …). Vervangt de eerdere Rust-specifieke regel.
