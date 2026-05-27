# Documentatiebeoordeling asd-tunnel-k8s

- **Datum:** 2026-05-27, 17:04 CEST
- **Beoordeeld door:** Nico (met Claude Code)
- **Doel:** Beoordeling van de documentatie op klant-readiness voor Redmine ticket #4013
- **Scope:** README.md + alle docs/ bestanden (7 stuks) + asd.yaml + Justfile

---

## Samenvatting

De documentatie is **goed tot zeer goed** voor een reference deployment. De README is uitgebreid, de architectuurdocumentatie is helder met ASCII-diagrammen, en de deployment-guides dekken meerdere scenario's. Er zijn een aantal verbeterpunten voor klant-facing gebruik.

**Eindoordeel:** 7.5/10 — solide technische documentatie, enkele aanpassingen nodig voor klantgerichte inzet.

---

## Per document

### README.md — Goed (8/10)

**Sterk:**
- Quick Start in <5 commando's, inclusief variant voor full cluster
- Duidelijke commandotabel met alle `asd run` taken
- Goede overzichtstabel voor deployment modes en benchmarks
- Docs-demo met complete architectuurflow is indrukwekkend

**Verbeterpunten:**
- De docs-demo sectie ("Documentation Demo") is lang en onduidelijk qua doel — een klant snapt niet direct dat dit een demonstratie is van de tunnel zelf
- Prerequisites mist versie-eisen (welke kubectl versie? welke Docker versie?)
- Geen troubleshooting sectie — als `asd run quickstart` faalt, is er geen handvat
- Link naar `asd-cli` GitHub repo staat er twee keer met verschillende context

### docs/architecture.md — Zeer goed (9/10)

**Sterk:**
- Uitstekende ASCII-diagrammen voor component layout, request flow en HA-scenario's
- Duidelijke uitleg van NATS subjects en hun doel
- Graceful drain vs. hard-kill recovery is helder met tijdlijn
- Resource allocation en networking poorten goed gedocumenteerd

**Verbeterpunten:**
- Geen vermelding van bekende limieten (max subdomain lengte, max concurrent tunnels per pod)
- StatefulSet design sectie is kort — mag uitleggen waarom StatefulSet i.p.v. Deployment

### docs/authentication.md — Goed (8/10)

**Sterk:**
- Twee auth-modes duidelijk beschreven met deploy-commando's
- HTTP-auth API contract is helder en bruikbaar voor custom validators
- Client-authenticatie optie voor productie is een mooie toevoeging

**Verbeterpunten:**
- Mist een overzichtsdiagram of beslisboom: "wanneer gebruik je file-auth vs. http-auth?"
- Key rotation procedure ontbreekt — hoe vervang je keys zonder downtime?
- Geen vermelding van wat er gebeurt bij auth-failure vanuit klantperspectief (foutmelding, logging)

### docs/quickstart.md — Goed (7.5/10)

**Sterk:**
- Stap-voor-stap, helder en beknopt
- Goede "Next Steps" links naar verdere documentatie
- Drie tunnel-varianten (basic, auth, client) aangeboden

**Verbeterpunten:**
- Dupliceert grotendeels de README Quick Start — onduidelijk welke de "bron van waarheid" is
- Mist verwachte output bij stap 3 (curl test) — klant weet niet wat "succes" eruit ziet
- Geen foutscenario's: wat als de port al bezet is? Wat als kind al draait?

### docs/benchmarking.md — Goed (7.5/10)

**Sterk:**
- Duidelijke test-beschrijvingen met pass-criteria
- "Interpreting Failures" tabel is zeer nuttig
- JSON output-formaat gedocumenteerd

**Verbeterpunten:**
- Mist referentiewaarden — wat zijn typische latency/throughput cijfers op standaard hardware?
- Stress test (`test-stress.sh`) en auth tests ontbreken in dit document, terwijl ze wel in de README staan
- Geen uitleg hoe je benchmarks interpreteert in context van productie-sizing

### docs/production-deployment.md — Zeer goed (8.5/10)

**Sterk:**
- Uitstekende vergelijkingstabel demo vs. productie
- Concrete sizing guidelines met schaalcategorieën
- Security hardening checklist met checkboxes (done vs. todo)
- DR-procedures voor pod failure, NATS split-brain en full cluster recovery
- TLS en monitoring secties met concrete config-voorbeelden

**Verbeterpunten:**
- HPA autoscaling staat als "niet included" maar er is geen guidance over hoe dit toe te voegen
- Helm chart wordt aanbevolen maar er is geen migratiepad beschreven
- Monitoring sectie noemt metrics maar levert geen voorbeeld Grafana dashboard of Prometheus rules

### docs/rolling-upgrade.md — Goed (7.5/10)

**Sterk:**
- Duidelijke uitleg van het PDB + rolling update mechanisme
- Monitor details met standalone gebruik
- Interpretatietabel voor resultaten

**Verbeterpunten:**
- "Common Issues" sectie beschrijft dat tunnel kan droppen bij restart — dit ondermijnt de "zero-downtime" claim. Moet duidelijker uitleggen dat de **client** moet reconnecten (asd-tunnel client doet dit automatisch, plain SSH niet)
- Mist vermelding van de `asd run` commando's — verwijst alleen naar shell scripts

### docs/airgap-deployment.md — Goed (8/10)

**Sterk:**
- Drie load-opties (registry, kind, containerd) — dekt de meeste scenario's
- Image digest pinning voor supply chain security
- Productie-overwegingen sectie is relevant

**Verbeterpunten:**
- Stap 5 (SSH keys) verwijst naar file-auth overlay maar de airgap overlay zelf erft daar niet automatisch van — dit kan verwarrend zijn
- Geen verificatiestap om te checken of images correct geladen zijn voordat je deployt
- Mist een offline-test procedure (hoe valideer je zonder internet dat alles werkt?)

---

## Overkoepelende bevindingen

### Wat goed is
1. **Consistente structuur** — elk document volgt een logisch patroon
2. **ASCII-diagrammen** — geen externe tools nodig, werken overal
3. **Meerdere deployment-modes** — 7 overlays met duidelijke use-cases
4. **Security-first** — hardening is standaard, niet een afterthought
5. **Concrete commando's** — copy-paste ready, geen abstracte stappen

### Wat beter kan voor klant-readiness

1. **Troubleshooting guide ontbreekt** — de meest kritische omissie. Klanten zullen problemen tegenkomen bij setup; er is geen document dat veelvoorkomende fouten en oplossingen beschrijft
2. **Duplicatie README ↔ quickstart.md** — verwarrend, kies één bron van waarheid
3. **Versie-eisen onduidelijk** — geen minimale versies voor Docker, kubectl, kind, jq
4. **Geen changelog/versioning** — klanten weten niet welke versie ze draaien of wat er veranderd is
5. **Foutscenario's onderbelicht** — documentatie beschrijft het happy path, maar niet wat er gebeurt als dingen misgaan vanuit klantperspectief
6. **Referentie-benchmarks ontbreken** — klanten willen weten wat ze kunnen verwachten qua performance
7. **`asd run` vs. `just` vs. shell scripts** — drie manieren om hetzelfde te doen, zonder duidelijke voorkeur voor klanten

### Aanbevelingen (geprioriteerd)

| Prio | Actie | Impact |
|------|-------|--------|
| 1 | Troubleshooting guide toevoegen | Vermindert support-load aanzienlijk |
| 2 | Prerequisites met versie-eisen | Voorkomt setup-frustratie |
| 3 | Quickstart.md samenvoegen met of verwijzen naar README | Eén bron van waarheid |
| 4 | Verwachte output toevoegen bij test-stappen | Klant weet wat "succes" is |
| 5 | Decision guide: welke overlay voor welk scenario | Klant kan sneller kiezen |
| 6 | Referentie-benchmarkresultaten publiceren | Verwachtingsmanagement |
| 7 | Key rotation en auth-failure documenteren | Productie-readiness |
