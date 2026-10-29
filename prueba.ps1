# Pruebas de Open-Meteo para Marante (issue #130). Compatible con PowerShell 5.1.
# Lanza las mismas peticiones que la app (src/domain/api.js + config.js) y
# variantes con models= fijados; guarda cada respuesta en resultados\<etiqueta>\.
#
#   .\prueba.ps1 -Etiqueta publico            # contra api.open-meteo.com (referencia)
#   .\prueba.ps1 -Etiqueta local -Local       # contra http://127.0.0.1:8080
#   .\prueba.ps1 -Comparar                    # compara resultados\local con resultados\publico
param(
  [string]$Etiqueta = 'publico',
  [switch]$Local,
  [switch]$Comparar,
  [double]$Lat = 43.290,   # CONFIG.DEFAULT_SPOT (Zarautz)
  [double]$Lon = -2.170
)
$ErrorActionPreference = 'Stop'
$dir = Join-Path $PSScriptRoot 'resultados'
$inv = [Globalization.CultureInfo]::InvariantCulture

function Num($x, $d) { $x.ToString("F$d", $inv) }

# --- Parametros exactos de la app ---
$HOURLY_CLIMA  = 'temperature_2m,precipitation,weather_code,cloud_cover,visibility,wind_speed_10m,wind_gusts_10m,wind_direction_10m,surface_pressure,pressure_msl'
$DAILY_CLIMA   = 'sunrise,sunset,uv_index_max,weather_code'
$HOURLY_MARINO = 'wave_height,wave_direction,wave_period,swell_wave_height,swell_wave_period,sea_surface_temperature,ocean_current_velocity,ocean_current_direction,sea_level_height_msl'
$comun = "timezone=auto&past_days=1&forecast_days=5"

function Rejilla($lat, $lon) {
  $n = 5; $paso = 0.06; $medio = ($n - 1) / 2; $la = @(); $lo = @()
  for ($i = 0; $i -lt $n; $i++) { for ($j = 0; $j -lt $n; $j++) {
    $la += Num ($lat + ($medio - $i) * $paso) 3; $lo += Num ($lon + ($j - $medio) * $paso) 3 } }
  "latitude=$($la -join ',')&longitude=$($lo -join ',')"
}

function Resumen($json) {
  # Devuelve por variable horaria: n valores, n nulos y media (ignorando nulos)
  $out = [ordered]@{}
  foreach ($bloque in 'hourly', 'daily') {
    $b = $json.$bloque; if (-not $b) { continue }
    foreach ($p in $b.PSObject.Properties) {
      if ($p.Name -eq 'time') { continue }
      $vals = @($p.Value); $nn = @($vals | Where-Object { $_ -ne $null }); $num = @($nn | Where-Object { $_ -isnot [string] })
      $media = if ($num.Count) { ($num | Measure-Object -Average).Average } else { $null }
      $out["$bloque.$($p.Name)"] = [pscustomobject]@{ n = $vals.Count; nulos = $vals.Count - $nn.Count; media = $media }
    }
  }
  $out
}

if ($Comparar) {
  $l = Join-Path $dir 'local'; $p = Join-Path $dir 'publico'
  foreach ($f in Get-ChildItem $l -Filter *.json) {
    $pf = Join-Path $p $f.Name; if (-not (Test-Path $pf)) { continue }
    $jl = Get-Content $f.FullName -Raw | ConvertFrom-Json; $jp = Get-Content $pf -Raw | ConvertFrom-Json
    if ($jl -is [array]) { $jl = $jl[0]; $jp = $jp[0] }
    if ($jl.error -or $jp.error) { "== $($f.BaseName): error local=$($jl.reason) publico=$($jp.reason)"; continue }
    "== $($f.BaseName)"
    $rl = Resumen $jl; $rp = Resumen $jp
    foreach ($k in $rl.Keys) {
      $a = $rl[$k]; $b = $rp[$k]
      $ma = if ($a.media -ne $null) { Num $a.media 2 } else { 'null' }
      $mb = if ($b -and $b.media -ne $null) { Num $b.media 2 } else { 'null' }
      "  {0,-42} local media={1,9} nulos={2,3}/{3,-3} | publico media={4,9} nulos={5,3}" -f $k, $ma, $a.nulos, $a.n, $mb, $b.nulos
    }
  }
  return
}

if ($Local) { $clima = 'http://127.0.0.1:8080/v1/forecast'; $marino = 'http://127.0.0.1:8080/v1/marine' }
else { $clima = 'https://api.open-meteo.com/v1/forecast'; $marino = 'https://marine-api.open-meteo.com/v1/marine' }
$pt = "latitude=$(Num $Lat 4)&longitude=$(Num $Lon 4)"

$casos = [ordered]@{
  # 1-3: exactamente lo que pide la app hoy (sin models=, best_match)
  '1_clima_app'          = "$clima`?$pt&hourly=$HOURLY_CLIMA&daily=$DAILY_CLIMA&$comun"
  '2_marino_app'         = "$marino`?$pt&hourly=$HOURLY_MARINO&$comun&cell_selection=sea"
  '3_corrientes_app'     = "$marino`?$(Rejilla $Lat $Lon)&hourly=ocean_current_velocity,ocean_current_direction,wave_height&timezone=auto&forecast_days=3"
  # 4-9: variantes con models= fijado (un solo modelo => mismos nombres de variable)
  '4_clima_icon_seamless'= "$clima`?$pt&hourly=$HOURLY_CLIMA&daily=$DAILY_CLIMA&$comun&models=icon_seamless"
  '5_clima_icon_eu'      = "$clima`?$pt&hourly=$HOURLY_CLIMA&daily=$DAILY_CLIMA&$comun&models=icon_eu"
  '6_clima_icon_global'  = "$clima`?$pt&hourly=$HOURLY_CLIMA&daily=$DAILY_CLIMA&$comun&models=icon_global"
  '7_uv_gfs013'          = "$clima`?$pt&daily=uv_index_max&$comun&models=gfs013"
  '8_nivel_mar_currents' = "$marino`?$pt&hourly=sea_level_height_msl,ocean_current_velocity,ocean_current_direction&$comun&cell_selection=sea&models=meteofrance_currents"
  '9_olas_mfwave'        = "$marino`?$pt&hourly=wave_height,wave_direction,wave_period,swell_wave_height,swell_wave_period&$comun&cell_selection=sea&models=meteofrance_wave"
}

$sal = Join-Path $dir $Etiqueta; New-Item -ItemType Directory -Force $sal | Out-Null
foreach ($k in $casos.Keys) {
  $url = $casos[$k]; $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 $url; $cuerpo = $r.Content; $code = $r.StatusCode
  } catch {
    $code = 0; $cuerpo = '{"error":true,"reason":"' + ($_.Exception.Message -replace '"', "'") + '"}'
    if ($_.Exception.Response) {
      $code = [int]$_.Exception.Response.StatusCode
      $cuerpo = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd()
    }
  }
  $sw.Stop()
  [IO.File]::WriteAllText((Join-Path $sal "$k.json"), $cuerpo)
  $j = $cuerpo | ConvertFrom-Json
  if ($j -is [array]) { $j = $j[0] }
  $nulos = if ($j.error) { "ERROR: $($j.reason)" } else {
    ((Resumen $j).GetEnumerator() | Where-Object { $_.Value.nulos -gt 0 } | ForEach-Object { "$($_.Key)=$($_.Value.nulos)/$($_.Value.n)" }) -join ' '
  }
  "{0,-24} HTTP {1} {2,6} ms  nulos: {3}" -f $k, $code, $sw.ElapsedMilliseconds, $nulos
}
