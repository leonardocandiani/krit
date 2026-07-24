# KRIT — Distribuição e Release

Cobre o ciclo completo: build local, DMG, notarização, Homebrew, CI de build e
auto-update via Sparkle.

---

## 1. Versionamento e release pública

O fluxo oficial é `scripts/release/release.sh`. Ele recebe a versão semver,
altera `CFBundleShortVersionString`, gera um build stamp para
`CFBundleVersion`, atualiza `WhatsNew.md`, changelog, appcast e cask, cria a tag
e só então publica o GitHub Release.

```bash
scripts/release/release.sh 0.29.0 notas-0.29.0.md
```

O script exige árvore limpa, `main` sincronizada, testes verdes, chave EdDSA do
Sparkle, certificado `Developer ID Application`, credenciais de notarização e
DMG com ticket stapled no modo padrão `notarized`. Ele monta o bundle de release
em `/tmp`, sem substituir o KRIT já instalado em `/Applications`.

Quando uma versão precisa manter compatibilidade com os artefatos públicos
históricos, o maintainer pode selecionar o modo legado explicitamente:

```bash
KRIT_RELEASE_MODE=adhoc scripts/release/release.sh 0.28.2 notas-0.28.2.md
```

Esse modo preserva os gates de testes, bundle universal, checksum, assinatura
EdDSA do Sparkle, tag e publicação atômica. Apenas a assinatura Apple e a
notarização são omitidas. O modo padrão continua sendo `notarized`.

---

## 2. Cadeia de release local (manual)

Os comandos abaixo servem para desenvolvimento e RC local. Cada script lê
`.env.local` automaticamente se o arquivo existir (copie `.env.example` e
preencha). Eles não substituem `scripts/release/release.sh` para publicação.

```bash
# 1. Compila e instala em /Applications/KRIT.app
bash build-app.sh

# 2. Gera KRIT-v<versão>-macOS.dmg no diretório raiz do projeto
bash make-dmg.sh

# 3. Notariza, staple e valida para distribuição externa
bash notarize-dmg.sh ./KRIT-v0.15.5-macOS.dmg
```

Use essa cadeia para depuração e inspeção. A publicação é feita somente pelo
script oficial, depois de todos os gates acima.

### Variáveis de ambiente lidas por cada script

| Variável | Script(s) | Valor padrão | Descrição |
|---|---|---|---|
| `KRIT_CODESIGN_IDENTITY` | build-app.sh, make-dmg.sh | `-` (ad-hoc) | Identidade de assinatura do codesign |
| `KRIT_CODESIGN_IDENTITY_OVERRIDE` | build-app.sh | não definido | Override interno usado pelo pipeline para sobrepor `.env.local` |
| `KRIT_DMG_SIGN_IDENTITY` | make-dmg.sh | valor de `KRIT_CODESIGN_IDENTITY` | Override explícito da assinatura do DMG; vazio mantém o DMG sem assinatura |
| `KRIT_RELEASE_MODE` | release.sh | `notarized` | Use `adhoc` apenas para uma release legada aprovada |
| `KRIT_DISABLE_SWIFTPM_SANDBOX` | build-app.sh | `0` | Use `1` apenas dentro de outra sandbox que impeça o SwiftPM de criar a própria |
| `KRIT_APP_PATH` | make-dmg.sh | `/Applications/KRIT.app` | Caminho do bundle já compilado |
| `KRIT_NOTARY_PROFILE` | notarize-dmg.sh | — | Nome do perfil no Keychain |
| `KRIT_DMG_PATH` | notarize-dmg.sh | — | Caminho do DMG (alternativa ao arg posicional) |

---

## 3. Identidade de assinatura e notarização

### Ad-hoc (`-`)

O padrão de desenvolvimento. Produz um `.app` funcional, mas sem identidade
Apple verificável e sem possibilidade de notarização. Também existe como modo
legado explícito no pipeline para manter compatibilidade com releases antigas.
Não deve substituir o fluxo `Developer ID` em versões futuras.

### Developer ID Application

Necessário para distribuição pública sem prompt do Gatekeeper. O caminho completo:

1. Instale o certificado "Developer ID Application" no Keychain de login
   (baixe em developer.apple.com → Certificates, Identifiers & Profiles).
2. Armazene as credenciais do notarytool no Keychain:
   ```bash
   xcrun notarytool store-credentials "KritNotaryProfile" \
     # interativo: pede Apple ID, senha de app específico, Team ID
   ```
3. Configure `.env.local`:
   ```bash
   KRIT_CODESIGN_IDENTITY="Developer ID Application: Seu Nome (TEAMID)"
   KRIT_NOTARY_PROFILE="KritNotaryProfile"
   ```
4. Execute `scripts/release/release.sh <versão> <notas>` para a publicação.

### Por que o staple importa

`notarize-dmg.sh` faz submit → wait → staple → validate. O staple incorpora o
ticket da Apple diretamente no DMG, permitindo que o Gatekeeper valide
**offline** (sem chamada ao servidor da Apple). Distribuir sem staple funciona
apenas com conexão à internet ativa.

### Pré-requisitos para notarização funcionar

- `.app` assinado com `--options runtime` (hardened runtime) — build-app.sh já faz isso.
- DMG assinado com Developer ID — make-dmg.sh já faz isso quando `KRIT_CODESIGN_IDENTITY` está configurado.
- Ambos são pré-requisitos do notarytool; enviar sem eles resulta em rejeição imediata.

---

## 4. CI de build

O repositório possui somente `.github/workflows/build-check.yml`. Ele roda em
pull requests relevantes e em disparo manual, compila o app universal e confere
as fatias `arm64` e `x86_64` dos binários entregues.

Não existe workflow de publicação. O release público roda na máquina do
maintainer pelo script oficial, porque ele depende do certificado Developer ID,
do perfil de notarização e da chave privada EdDSA do Sparkle. Não configure um
workflow que publique artefato ad-hoc como substituto desse fluxo.

---

## 5. Homebrew: `Casks/krit.rb`

### Publicando o tap

```bash
# Crie o repositório homebrew-krit no GitHub (nome obrigatório para tap)
# Copie Casks/krit.rb para ele e atualize o sha256

brew tap leonardocandiani/krit https://github.com/leonardocandiani/homebrew-krit
brew install --cask leonardocandiani/krit/krit
```

### Acoplamento crítico — não quebre

O nome do artefato deve ser **idêntico** em três lugares:

| Lugar | Valor |
|---|---|
| `make-dmg.sh` (variável `DMG_NAME`) | `KRIT-v$VERSION-macOS` |
| `Casks/krit.rb` (campo `url`) | `KRIT-v#{version}-macOS.dmg` |
| `scripts/release/release.sh` | `KRIT-v$VERSION-macOS.dmg` |

Qualquer divergência faz o `brew install` baixar uma URL 404.

### sha256

O script oficial calcula o SHA-256 do DMG publicado e atualiza
`Casks/krit.rb` no commit de release. O tap externo, se usado, deve receber a
mesma alteração depois que a tag e o asset público existirem.

### Nota sobre Gatekeeper

O cask e `install.sh` verificam a assinatura do bundle antes de concluir. Para
uma assinatura `Developer ID`, eles preservam o atributo de quarantine para que
o Gatekeeper valide a identidade e o ticket stapled. Para uma release legada
ad-hoc, removem quarantine somente depois de confirmar `Signature=adhoc`,
replicando o comportamento necessário dos instaladores históricos.

---

## 6. Sparkle auto-update

Sparkle já está integrado no pacote, no `Info.plist`, no menu de atualizações e
no appcast. A chave pública EdDSA fica no bundle; a chave privada permanece no
Keychain do maintainer.

Em cada release, `scripts/release/release.sh` assina o DMG com `sign_update`,
atualiza `appcast.xml` com versão, build stamp, tamanho, URL e assinatura, e só
envia o appcast para `main` depois que o asset da GitHub Release está público.
Essa ordem impede que o app anuncie uma atualização cujo download ainda não
existe.
