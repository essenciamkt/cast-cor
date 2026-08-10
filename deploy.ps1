# ============================================================
#  CastCor - gera o pacote de deploy para a Hostinger
#  Uso:  .\deploy.ps1
# ============================================================
#  Faz a build, RECUSA subir se algo perigoso estiver no dist,
#  e gera um zip pronto para extrair em public_html.
# ============================================================

$ErrorActionPreference = "Stop"
$raiz = $PSScriptRoot
$dist = Join-Path $raiz "dist"

Write-Host ""
Write-Host "==> 1/4  Build" -ForegroundColor Cyan
Push-Location $raiz
npx astro build
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "A build falhou. Nada foi gerado." }
Pop-Location

Write-Host ""
Write-Host "==> 2/4  Verificacoes de seguranca" -ForegroundColor Cyan

$falhas = @()

# 1. .htaccess NUNCA pode ir junto - ele sobrescreve o do servidor.
#    Foi isso que derrubou o site em 02/08/2026 (conflito mod_deflate x LiteSpeed).
if (Test-Path (Join-Path $dist ".htaccess")) {
    $falhas += "O dist contem .htaccess. Ele sobrescreveria o do servidor e derruba o dominio inteiro."
}

# 2. Nada de zip ou backup dentro do dist - subiria para o servidor.
$intrusos = Get-ChildItem $dist -Recurse -Include *.zip,*.rar,*.bak,*.7z -ErrorAction SilentlyContinue
if ($intrusos) {
    $falhas += "Arquivos que nao pertencem a build: $($intrusos.Name -join ', ')"
}

# 3. Todo CSS/JS que o HTML pede precisa existir no dist.
#    Hash descasado = pagina sem estilo (o erro classico aqui).
$htmls = Get-ChildItem $dist -Recurse -Filter index.html
foreach ($html in $htmls) {
    $texto = Get-Content $html.FullName -Raw
    foreach ($m in [regex]::Matches($texto, '(?:href|src)="(/_astro/[^"]+)"')) {
        $alvo = Join-Path $dist $m.Groups[1].Value.TrimStart('/')
        if (-not (Test-Path $alvo)) {
            $falhas += "$($html.FullName.Replace($dist,'')) pede $($m.Groups[1].Value), que nao existe no dist."
        }
    }
}

if ($falhas.Count -gt 0) {
    Write-Host ""
    Write-Host "  BLOQUEADO - nao gere o pacote:" -ForegroundColor Red
    $falhas | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    throw "Deploy interrompido."
}
Write-Host "    ok - sem .htaccess, sem arquivos estranhos, assets todos presentes" -ForegroundColor Green

Write-Host ""
Write-Host "==> 3/4  Gerando o zip" -ForegroundColor Cyan
$carimbo = Get-Date -Format "yyyyMMdd-HHmm"
$zip = Join-Path (Split-Path $raiz -Parent) "deploy-castcor-$carimbo.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }

# NAO usar Compress-Archive: no PowerShell 5.1 ele grava os caminhos com
# barra invertida ("telhados\index.html"), o que viola o padrao ZIP. Certos
# extratores criam um arquivo com esse nome literal em vez da pasta.
# Aqui montamos as entradas na mao, sempre com barra normal.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$fs = [System.IO.File]::Open($zip, [System.IO.FileMode]::Create)
$arquivo = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $prefixo = (Resolve-Path $dist).Path.TrimEnd('\') + '\'
    foreach ($item in Get-ChildItem $dist -Recurse -File) {
        $nome = $item.FullName.Substring($prefixo.Length).Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $arquivo, $item.FullName, $nome,
            [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    $arquivo.Dispose()
    $fs.Dispose()
}

$mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host "    $zip  ($mb MB)" -ForegroundColor Green

Write-Host ""
Write-Host "==> 4/4  Como subir" -ForegroundColor Cyan
Write-Host @"

  1. File Manager da Hostinger -> public_html
  2. NAO apague nada. As pastas portas/, lp-porta/ e revestimentos/
     sao de outros projetos e nao estao neste zip.
  3. Envie o zip e use "Extract" ali mesmo, sobrescrevendo.
  4. Confira que o .htaccess da raiz NAO foi alterado.
  5. Teste NO NAVEGADOR (Ctrl+Shift+R), nao por curl:
       /telhados/       com estilo
       /portas/         carregando
       /revestimentos/  carregando

"@
