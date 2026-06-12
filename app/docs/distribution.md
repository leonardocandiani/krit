# KRIT — Distribuição e Release

Cobre o ciclo completo: build local, DMG, notarização, Homebrew, CI, e o plano
de auto-update (Sparkle — G3, ainda não implementado).

---

## 1. Versionamento

Antes de cada release:

1. Edite `Info.plist`:
   - `CFBundleShortVersionString` — versão pública (ex: `0.15.5`)
   - `CFBundleVersion` — build number incremental (ex: `24`)
2. Commite a mudança na `main`.
3. Crie e empurre a tag:
   ```bash
   git tag v0.15.5
   git push origin v0.15.5
   ```
   O push da tag dispara o workflow de CI automaticamente.

---

## 2. Cadeia de release local (manual)

Quatro comandos na ordem correta. Cada script lê `.env.local` automaticamente
se o arquivo existir (copie `.env.example` e preencha).

```bash
# 1. Compila e instala em /Applications/KRIT.app
bash build-app.sh

# 2. Gera KRIT-v<versão>-macOS.dmg no diretório raiz do projeto
bash make-dmg.sh

# 3. (Opcional) Notariza, staple e valida — requer Developer ID
bash notarize-dmg.sh ./KRIT-v0.15.5-macOS.dmg

# 4. Faça upload do DMG para o release no GitHub
#    (o CI faz isso automaticamente via softprops/action-gh-release)
```

### Variáveis de ambiente lidas por cada script

| Variável | Script(s) | Valor padrão | Descrição |
|---|---|---|---|
| `KRIT_CODESIGN_IDENTITY` | build-app.sh, make-dmg.sh | `-` (ad-hoc) | Identidade de assinatura do codesign |
| `KRIT_CODESIGN_TIMESTAMP` | build-app.sh | `auto` | Modo de timestamp do codesign |
| `KRIT_APP_PATH` | make-dmg.sh | `/Applications/KRIT.app` | Caminho do bundle já compilado |
| `KRIT_NOTARY_PROFILE` | notarize-dmg.sh | — | Nome do perfil no Keychain |
| `KRIT_DMG_PATH` | notarize-dmg.sh | — | Caminho do DMG (alternativa ao arg posicional) |

---

## 3. Identidade de assinatura e notarização

### Ad-hoc (`-`)

O padrão. Produz um `.app` funcionando localmente mas **não distribu&iacute;vel via
Gatekeeper**. Não pode ser notarizado. Suficiente para desenvolvimento e testes
internos.

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
4. Execute os três scripts na ordem acima.

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

## 4. CI — `.github/workflows/release.yml`

Dispara em qualquer push de tag `v*`. Job único em `macos-14` (Apple Silicon).

### Segredos que o workflow usa

Configure em Settings → Secrets → Actions do repositório:

| Segredo | Quando necessário | Descrição |
|---|---|---|
| `DEVELOPER_ID_CERT_P12` | Assinatura com Developer ID | Certificado em base64 (`base64 -i cert.p12`) |
| `DEVELOPER_ID_CERT_PASSWORD` | Assinatura com Developer ID | Senha do arquivo .p12 |
| `KEYCHAIN_PASSWORD` | Assinatura com Developer ID | Senha para o keychain temporário do runner |
| `NOTARY_APPLE_ID` | Notarização | Apple ID da conta de desenvolvedor |
| `NOTARY_PASSWORD` | Notarização | Senha específica de app (nunca a senha principal) |
| `NOTARY_TEAM_ID` | Notarização | Team ID da conta Apple Developer |

**Quando nenhum segredo está configurado**, o workflow ainda funciona: compila
com ad-hoc, gera o DMG e publica o artefato no release — apenas sem notarização.

### Diferença entre local e CI para notarização

- **Local**: `notarize-dmg.sh` usa `--keychain-profile` (perfil armazenado interativamente).
- **CI**: O workflow armazena o perfil de forma não interativa antes de chamar o script:
  ```bash
  xcrun notarytool store-credentials "KritNotaryProfile" \
    --apple-id "$NOTARY_APPLE_ID" \
    --password "$NOTARY_PASSWORD" \
    --team-id "$NOTARY_TEAM_ID"
  ```
  Depois chama `notarize-dmg.sh` normalmente — o mesmo script serve para ambos os cenários.

### Artefato produzido

O CI imprime o sha256 do DMG no resumo do job. Copie esse valor para
`Casks/krit.rb` (campo `sha256`) antes de publicar o tap.

---

## 5. Homebrew — `Casks/krit.rb`

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
| CI upload (`release.yml`, campo `files`) | `KRIT-v*-macOS.dmg` (glob) |

Qualquer divergência faz o `brew install` baixar uma URL 404.

### sha256

Após cada release:
1. Copie o sha256 do resumo do job de CI.
2. Atualize `sha256` em `Casks/krit.rb`.
3. Commite e empurre no repositório do tap.

### Nota sobre Gatekeeper

O cask funciona sem prompt apenas com DMG notarizada. Antes de G1 estar em
produção, usuários que instalarem via tap receberão o aviso "desenvolvedor
não identificado" e precisarão contorná-lo manualmente.

---

## 6. G3 — Sparkle auto-update (TODO, não implementado)

> **Não adicione esta dependência agora.** A adição do Sparkle ao `Package.swift`
> afeta o build SPM de todos os clusters. Implemente apenas quando o ciclo de
> parity estiver estável.

### Plano de implementação

**Dependência SPM** (adicionar em `Package.swift` quando G3 for implementado):

```swift
.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
// adicionar "Sparkle" ao target de dependências do app
```

**Wiring em AppDelegate** (`Sources/Krit/App/AppDelegate.swift`):

```swift
import Sparkle

// Propriedade no AppDelegate:
private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
)

// Item de menu "Verificar atualizações…":
@IBAction func checkForUpdates(_ sender: Any) {
    updaterController.checkForUpdates(sender)
}
```

**Chaves em `Info.plist`** (adicionar quando G3 for implementado):

| Chave | Valor exemplo | Descrição |
|---|---|---|
| `SUFeedURL` | `https://leonardocandiani.github.io/krit/appcast.xml` | URL do appcast |
| `SUPublicEDKey` | `<chave pública EdDSA>` | Verificação de assinatura das atualizações |
| `SUEnableAutomaticChecks` | `YES` | Checagem automática na inicialização |

**Chaves em `Settings.swift`** (scaffold a adicionar junto com G3):

```swift
// Padrão enum de Settings.swift já existente no projeto:
case automaticallyChecksForUpdates  // Bool, default true
case lastUpdateCheckDate             // Date?, default nil
```

**CI — appcast.xml** (adicionar ao `release.yml` quando G3 for implementado):

```bash
# Gera e assina o appcast após cada release
generate_appcast --ed-key-file sparkle_private_key .
# Publica appcast.xml no GitHub Pages ou junto ao release
```

O Sparkle verifica a assinatura EdDSA de cada delta/full package antes de
instalar — a chave privada fica apenas em `.env.local` (nunca no repositório)
e a chave pública entra no `Info.plist`.
