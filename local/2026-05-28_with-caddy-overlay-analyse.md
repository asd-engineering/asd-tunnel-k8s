# Analyse: with-caddy overlay — code-bug of documentatie-bug?

- **Datum:** 2026-05-28
- **Doel:** Helderheid krijgen of het probleem in de code (de overlay zelf) of in de documentatie (de README tabel) zit
- **Aanleiding:** Tweede audit vond dat ik tijdens de eerste audit-fix een regressie introduceerde

---

## Wat zegt de huidige code precies?

### `k8s/base/statefulset.yaml` (regel 61-62)

```yaml
- name: ASD_TUNNEL_AUTHENTICATION
  value: "true"
```

Authentication staat in de **base** standaard aan. Elke overlay erft dit, tenzij hij het expliciet patcht.

### `k8s/overlays/with-caddy/kustomization.yaml`

```yaml
resources:
  - ../../base
  - caddy-configmap.yaml      # Caddy config
  - service-caddy.yaml         # NodePort voor HTTPS
patches:
  - path: patch-caddy-sidecar.yaml      # Voegt Caddy sidecar container toe
  - path: patch-networkpolicy.yaml      # Staat caddy port toe
```

Wat de overlay doet:
- Voegt Caddy sidecar toe voor TLS termination
- Geen `pubkeys-configmap.yaml` resource
- Geen patch op `ASD_TUNNEL_AUTHENTICATION`
- Geen volume mount voor `/etc/tunnel/pubkeys/`

### Wat is dus de feitelijke runtime-staat?

| Aspect | Waarde |
|--------|--------|
| `ASD_TUNNEL_AUTHENTICATION` | `true` (geërfd van base) |
| `ASD_TUNNEL_AUTHENTICATION_KEYS_DIRECTORY` | `/etc/tunnel/pubkeys/` (default in image) |
| Inhoud van `/etc/tunnel/pubkeys/` in de pod | **Niets** — geen ConfigMap gemount |

**Gevolg:** elke SSH-verbinding wordt geweigerd, want er zijn geen authorized keys.

---

## Wat zei de README op verschillende momenten?

| Versie | `with-caddy` auth-kolom | Klopt? |
|--------|------------------------|--------|
| Origineel (vóór onze branch) | "SSH public keys" | Misleidend — er zijn geen keys gemount |
| Na mijn eerste fix (commit `350da03`) | "None" | Fout — auth staat aan |
| Werkelijkheid | "Auth required, no keys mounted — onbruikbaar zonder eigen patch" | — |

---

## Is dit een code-bug of een documentatie-bug?

**Beide.** Maar de root cause zit in de **code**.

### De code-bug

De `with-caddy` overlay is **incompleet**. Hij belooft een werkende TLS deployment, maar zonder bijkomende patch werkt geen enkele SSH verbinding. Voor een reference deployment is dit problematisch — een klant die `OVERLAY=with-caddy asd run deploy` draait krijgt pods die wel starten maar waar geen tunnel doorheen kan.

Het feit dat er een aparte `with-caddy-noauth` overlay bestaat, suggereert dat de oorspronkelijke auteur zich bewust was van dit gat. `with-caddy-noauth` is de "werkende" variant voor demos. `with-caddy` zonder keys is feitelijk nooit uit te voeren.

### De documentatie-bug

De README tabel suggereert dat `with-caddy` als losse overlay bruikbaar is. Dat klopt niet — hij is een vertrekpunt waar je je eigen keys aan moet toevoegen. Geen enkele waarde in de auth-kolom maakt dit duidelijk.

---

## Mogelijke fixes

### Optie A — Alleen de tabel aanpassen (documentatie-fix)

Zet in de README dat `with-caddy` "Bring your own keys" vereist:

```
| `with-caddy` | 3 | BYO SSH keys | HTTPS via Caddy sidecar (keys not included) |
```

**Voor:** kleine wijziging, geen risico op breken van bestaande deployments
**Tegen:** verbergt dat de overlay incompleet is; klant moet zelf uitzoeken hoe keys te mounten

### Optie B — `with-caddy` automatisch laten erven van `file-auth` (code-fix)

Maak `with-caddy` een combinatie: Caddy + file-auth + auto-generated demo key.

```yaml
# k8s/overlays/with-caddy/kustomization.yaml
resources:
  - ../../base
  - ../file-auth/pubkeys-configmap.yaml
  - caddy-configmap.yaml
  - service-caddy.yaml
patches:
  - path: ../file-auth/patch-file-auth.yaml
  - path: patch-caddy-sidecar.yaml
  - path: patch-networkpolicy.yaml
```

**Voor:** overlay werkt out-of-the-box, consistent met `quickstart-full` flow
**Tegen:** verandert de bedoeling van de overlay; misschien wilde de auteur het juist generiek houden

### Optie C — `with-caddy` verwijderen, alleen `with-caddy-noauth` en een nieuwe `with-caddy-file-auth` houden

Splits expliciet in twee bruikbare overlays, verwijder de incomplete tussenvariant.

**Voor:** duidelijkste structuur, elke overlay werkt
**Tegen:** breaking change voor wie de overlay nu wel gebruikt (met eigen patches)

### Optie D — Status quo + warning in de docs

Laat de code zoals hij is, maar voeg een waarschuwing toe in zowel de README tabel als `docs/authentication.md`:

> `with-caddy` is a template overlay — auth is enabled but no keys are mounted.
> You must provide your own `pubkeys-configmap.yaml` or extend from `file-auth`.

**Voor:** minste invasief, behoudt originele intentie
**Tegen:** klant moet eerst lezen voor het te gebruiken; in lijn met "het werkt niet vanzelf"

---

## Opties om met de originele code te werken (zonder overlay aan te passen)

Als je de overlay-code zelf onaangetast wilt laten, hier zijn de mogelijkheden om `with-caddy` werkend te krijgen:

### Optie 1 — ConfigMap los toevoegen na deploy

```bash
OVERLAY=with-caddy asd run deploy

# Voeg keys toe vanuit file-auth overlay
kubectl create configmap tunnel-pubkeys \
  --from-file=k8s/overlays/file-auth/ssh-keys/ \
  -n asd-tunnel-demo
```

**Probleem:** dit werkt niet automatisch. Je moet ook nog de StatefulSet patchen om de ConfigMap als volume te mounten op `/etc/tunnel/pubkeys/`. Veel handwerk, niet declaratief.

### Optie 2 — Eigen overlay die `with-caddy` uitbreidt (aanbevolen)

Maak `k8s/overlays/my-caddy/kustomization.yaml`:

```yaml
resources:
  - ../with-caddy
  - ../file-auth/pubkeys-configmap.yaml
patches:
  - path: ../file-auth/patch-file-auth.yaml
```

Dan: `OVERLAY=my-caddy asd run deploy`. Werkt zonder de originele `with-caddy` overlay te raken.

**Implicatie:** als dit de bedoelde flow is, dan is `with-caddy` een **bouwsteen**, niet een zelfstandige overlay. De README tabel moet dit duidelijk maken — bijvoorbeeld met de annotatie "template" of "bouwsteen" in plaats van het te presenteren als deploybare overlay.

### Optie 3 — Auth uitschakelen via patch

`with-caddy-noauth` doet dit al expliciet:

```bash
OVERLAY=with-caddy-noauth asd run deploy
```

Dit is geen nieuwe oplossing — het is een bevestiging dat `with-caddy-noauth` precies voor dit scenario bestaat. Als je geen auth wilt, gebruik dan deze. Als je wel auth wilt, gebruik dan optie 2.

### Optie 4 — Demo key handmatig genereren + ConfigMap + StatefulSet patchen

```bash
./scripts/generate-demo-key.sh
kubectl apply -f k8s/overlays/file-auth/pubkeys-configmap.yaml -n asd-tunnel-demo
kubectl edit statefulset asd-tunnel -n asd-tunnel-demo   # voeg volume + volumeMount toe
```

Veel handwerk, niet reproduceerbaar, niet declaratief. Niet aanbevolen.

---

## Synthese

Als de code onaangetast moet blijven, is **optie 2** (eigen wrapper-overlay) de enige schone reproduceerbare manier. Dit suggereert sterk dat `with-caddy` ontworpen is als **bouwsteen**, niet als eindpunt. Twee implicaties:

1. **Documentatie moet dit communiceren** — de huidige README presenteert `with-caddy` als een van de 7 gelijkwaardige overlays, wat de bedoeling verkeerd weergeeft
2. **Het zou helpen om een voorbeeld-overlay mee te leveren** — bijv. `k8s/overlays/with-caddy-file-auth/` als concrete bouwsteen-compositie die laat zien hoe je `with-caddy` met `file-auth` combineert

## Vraag aan jou (Nico)

1. Welke optie uit "Mogelijke fixes" wil je doorvoeren in deze branch?
2. Is de `with-caddy` overlay ooit bedoeld als zelfstandig draaibare reference, of altijd als basis voor je eigen overlay (bouwsteen)?
3. Wil je dit als bevinding voor de core developer noteren (alleen documentatie aanpassen), of in deze branch direct in code oplossen?

## Voor de core developer

Als je dit document leest: de essentie is dat `with-caddy` momenteel auth aanlaat zonder keys te mounten, waardoor de overlay onbruikbaar is zonder bijkomende patch. De vraag is of dit een **ontwerpkeuze** is (overlay als bouwsteen) of een **fout** (vergeten keys mount toe te voegen). Beide vragen om actie — alleen het type actie verschilt.
