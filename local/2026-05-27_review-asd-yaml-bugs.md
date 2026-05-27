# Review: asd.yaml — runtime fouten bij klantgebruik

- **Datum:** 2026-05-27, 16:00 CEST
- **Beoordeeld door:** Nico (met Claude Code)
- **Doel:** Identificatie van blokkers in de asd.yaml die klantacceptatie verhinderen
- **Ticket:** Redmine #4013

---

## Bevinding: `backgroundTeardownCommand` bestaat niet in ASD CLI

### Probleem

De `_port-forward` shared step in `asd.yaml` (regel 127-131) gebruikt de key `backgroundTeardownCommand`:

```yaml
_port-forward:
  - name: Port-forward validation-server
    run: kubectl port-forward -n ... svc/validation-server ...
    background: true
    backgroundTeardownCommand: "pkill -f 'port-forward.*validation-server.*' || true"
```

Dit veroorzaakt een YAML-validatiefout bij het draaien van elk commando dat `_port-forward` gebruikt:

```
❌ YAML validation failed for "asd-tunnel-k8s.automation.tunnel":
- steps.0: Unrecognized key(s) in object: 'backgroundTeardownCommand'
```

### Impact

De volgende commando's zijn **volledig geblokkeerd**:

| Commando | Reden |
|----------|-------|
| `asd run tunnel` | `uses: _port-forward` |
| `asd run tunnel-auth` | `uses: _port-forward` |
| `asd run tunnel-client` | `uses: _port-forward` |
| `asd run bench-stress` | `uses: _port-forward` |
| `asd run bench-auth` | `uses: _port-forward` |
| `asd run bench-auth-http` | `uses: _port-forward` |
| `asd run bench-resilience` | `uses: _port-forward` |
| `asd run bench-resource-limits` | `uses: _port-forward` |

Dit blokkeert de **gehele tunnel- en benchmarkflow** — precies de kernfunctionaliteit die een klant wil testen.

### Tweede occurrence

Dezelfde key wordt ook gebruikt in de `docs` task:

```yaml
docs:
  - name: Start docs container
    run: docker run --rm --name asd-docs-demo ...
    background: true
    backgroundTeardownCommand: "docker stop asd-docs-demo 2>/dev/null || true"
```

### Onderzoek: heeft `backgroundTeardownCommand` ooit bestaan?

**Nee.** Binaire analyse van twee beschikbare ASD CLI versies:

| Versie | `backgroundTeardownCommand` gevonden? | `onDown` gevonden? |
|--------|---------------------------------------|-------------------|
| v2.9.3-beta.2 | Nee | Ja |
| v2.11.0 (huidig) | Nee | Ja |

De key `backgroundTeardownCommand` komt in **geen enkele beschikbare versie** voor. De correcte key is `onDown`, met de volgende signatuur:

```
name: "onDown"
type: "string | { run | command }"
description: "Cleanup hook for this step's external state — runs when `asd down`
is invoked, in reverse-LIFO order."
```

### Conclusie

Dit is een bug in de originele repo. De key `backgroundTeardownCommand` is vermoedelijk een concept geweest dat nooit geïmplementeerd is, of een naamgeving uit een onbekende oudere versie die niet beschikbaar is voor verificatie.

### Voorgestelde fix

Vervang `backgroundTeardownCommand` door `onDown` op beide plaatsen:

```yaml
# _port-forward
- name: Port-forward validation-server
  run: kubectl port-forward -n ... svc/validation-server ...
  background: true
  onDown: "pkill -f 'port-forward.*validation-server.*' || true"

# docs
- name: Start docs container
  run: docker run --rm --name asd-docs-demo ...
  background: true
  onDown: "docker stop asd-docs-demo 2>/dev/null || true"
```

### Toegepaste fix

`backgroundTeardownCommand` is vervangen door `onDown` op beide plaatsen in `asd.yaml` (branch `4013/klant-onboarding-review`).

### Opruimen na de fout

Als de fout eerder is opgetreden, laat de ASD CLI stale cache en logs achter. De volgende commando's zijn nodig om weer schoon te starten:

```bash
# 1. Stop workspace en ruim teardown-manifests op
asd down

# 2. Wis logbestanden (oude foutmeldingen blijven anders zichtbaar)
asd logs clear

# 3. Herstart de taak
asd run tunnel
```

**Waarom is dit nodig?**

- `asd down` — ruimt het teardown-manifest op in `.asd/workspace/network/teardown/`. Zonder dit blijft de CLI de oude (foutieve) stap-definitie herhalen.
- `asd logs clear` — het logbestand (`srv-project-tunnel.log`) wordt niet geleegd tussen runs. Oude foutmeldingen verschijnen daardoor opnieuw bij `Following logs`, wat verwarrend is.
- De foutmelding `Unrecognized key(s) in object: 'backgroundTeardownCommand'` verschijnt ook nadat de YAML gefixt is, totdat bovenstaande stappen zijn uitgevoerd.

### Risico als dit niet gefixt wordt

Een klant die de Quick Start volgt komt bij stap "maak een tunnel" en krijgt een cryptische YAML-validatiefout. Dit is een **direct afhaakmoment** — de kernfunctionaliteit is onbereikbaar.

---

## Bevinding: Demo SSH private key ontbreekt — `asd run tunnel-auth` faalt

### Probleem

De `tunnel-auth` task verwijst naar de private key `k8s/overlays/file-auth/ssh-keys/demo`, maar dit bestand is bewust ge-gitignored (`.gitignore` regel 24). Alleen `demo.pub` zit in de repo.

Bij een verse clone faalt `asd run tunnel-auth` met:

```
Warning: Identity file k8s/overlays/file-auth/ssh-keys/demo not accessible: No such file or directory.
nicow@127.0.0.1: Permission denied (publickey).
```

### Impact

- `asd run tunnel-auth` — faalt direct
- `asd run quickstart-full` gevolgd door `asd run tunnel-auth` — faalt
- De volgende documenten verwijzen naar de private key zonder te vermelden dat deze gegenereerd moet worden:
  - `docs/authentication.md` (regel 51) — `--auth k8s/overlays/file-auth/ssh-keys/demo`
  - `docs/rolling-upgrade.md` (regel 31) — `--auth k8s/overlays/file-auth/ssh-keys/demo`
- Alleen `docs/airgap-deployment.md` (regel 125) noemt `ssh-keygen` als handmatige stap

### Oorzaak

Het generecommando staat als comment in `.gitignore`:

```
# SSH private keys (generate with: ssh-keygen -t ed25519 -f demo -C demo@asd-tunnel-k8s)
k8s/overlays/file-auth/ssh-keys/demo
```

Maar deze instructie is **nergens zichtbaar** voor een klant — niet in de README, niet in de quickstart, niet in de foutmelding.

### Toegepaste fix

Automatische key-generatie toegevoegd als stap in `quickstart-full` in `asd.yaml`:

```yaml
- name: Generate demo SSH keypair
  run: |
    if [ ! -f k8s/overlays/file-auth/ssh-keys/demo ]; then
      ssh-keygen -t ed25519 -f k8s/overlays/file-auth/ssh-keys/demo -C "demo@asd-tunnel-k8s" -N ""
    else
      echo "Demo keypair already exists, skipping"
    fi
```

De stap is idempotent — als de key al bestaat, wordt deze overgeslagen.

### Risico als dit niet gefixt wordt

Een klant die de "Full Cluster" quickstart volgt (`asd run quickstart-full` → `asd run tunnel-auth`) krijgt een `Permission denied` fout zonder duidelijke oplossing. Dit is het tweede commando dat een klant probeert na de installatie — een directe blocker.
