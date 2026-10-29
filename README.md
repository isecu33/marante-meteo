# Prueba de Open-Meteo self-hosted (Marante #130)

Prueba de concepto de [isecu33/marante#130](https://github.com/isecu33/marante/issues/130):
levantar Open-Meteo con Docker, sincronizado desde el bucket abierto de AWS
(`openmeteo.s3.amazonaws.com`, CC BY 4.0) **solo para la península ibérica + Baleares**
(`--bounding-box 35.5,-10.5,44.5,4.5`), y comprobar si sirve lo que pide la app.

## Ficheros

| Fichero | Para qué |
| --- | --- |
| `docker-compose.yml` | `sync` (descarga recortada, cada 30 min) + `api` (servidor en `127.0.0.1:8080`, solo datos locales) |
| `prueba.ps1` | Lanza las peticiones exactas de la app (`src/domain/api.js`) y variantes con `models=`; guarda JSON en `resultados\<etiqueta>\` |
| `resultados\publico\` | Respuestas de referencia de `api.open-meteo.com` (27-10-2026) |

## Estado (27-10-2026)

**Docker no arrancó**: Docker Desktop 4.84 está instalado pero, al abrirlo, muestra el
diálogo *"Docker Desktop - Update Failed: Failed to apply delta update"* (Continue/Quit)
y el motor no llega a levantarse (`docker info` no conecta con
`dockerDesktopLinuxEngine`; la distro WSL `docker-desktop` sigue parada). No se tocó
nada de la instalación ni de la configuración.

Para seguir: pulsa **Continue** en ese diálogo (según el propio mensaje, la versión
anterior está restaurada y lista). Si el motor sigue sin arrancar, reinstala Docker
Desktop desde docker.com.

## Pasos (cuando Docker funcione)

```powershell
cd D:\Workspace\marante-meteo-prueba
Get-PSDrive C,D                                   # espacio libre ANTES
docker compose pull
docker compose up -d sync                         # empieza la descarga recortada
docker compose logs -f sync                       # esperar a "... finished" de los 7 modelos
docker compose run --rm --entrypoint du sync -sh /app/data      # disco total
docker compose run --rm --entrypoint sh sync -c "du -sh /app/data/*"   # por modelo
# Si pasa de ~20 GB: docker compose stop sync

docker compose up -d api
.\prueba.ps1 -Etiqueta local -Local               # mismas peticiones contra 127.0.0.1:8080
.\prueba.ps1 -Comparar                            # local vs publico, variable a variable
docker stats --no-stream marante-meteo-api marante-meteo-sync   # RAM

docker compose stop                               # dejar parado
# Borrar todo (datos incluidos): docker compose down -v
```

Si `prueba.ps1` no se deja ejecutar: `powershell -ExecutionPolicy Bypass -File .\prueba.ps1 ...`.

Notas:

- El `sync` usa nombres **almacenados** (`wind_u_component_10m`, `ocean_u_current`...);
  las variables que no existen en un modelo se ignoran sin error.
- Al cambiar el `--bounding-box` hay que empezar con el volumen vacío (`docker compose down -v`).
- El servidor sin `REMOTE_DATA_DIRECTORY` solo ve lo sincronizado. Para comparar con el
  modo remoto con caché, añade a `api` `REMOTE_DATA_DIRECTORY: https://openmeteo.s3.amazonaws.com/data/`.

## Resultados hasta ahora (sin servidor local)

Comprobado listando el bucket (`?list-type=2&prefix=data/<modelo>/&delimiter=/`) y con
`.\prueba.ps1 -Etiqueta publico` (Zarautz, 43.29 / -2.17):

1. **`sea_level_height_msl` SÍ está publicado**: `data/meteofrance_currents/` tiene
   `sea_level_height_msl/`, `ocean_u_current/`, `ocean_v_current/`,
   `invert_barometer_height/` y `static/`. Último chunk escrito el 27-10-2026 12:05 UTC
   (`meta.json`: paso 1 h, actualización cada 24 h). Cada chunk global de 15 días pesa
   ~640 MB (con el recorte se descarga solo la parte ibérica).
2. Variables por modelo en el bucket (lo relevante para `models=`):
   - `dwd_icon` (global) **no tiene `visibility`**; `dwd_icon_eu` sí.
   - `uv_index` solo en `ncep_gfs013`.
   - `meteofrance_wave` y `dwd_ewam` tienen todas las de olas/mar de fondo que pide la app;
     `meteofrance_sea_surface_temperature` tiene `sea_surface_temperature`.
   - Sí hay ensembles en el bucket (`dwd_icon_eps`, `ecmwf_ifs025_ensemble`, `ncep_gefs025`...),
     al contrario de lo que decía el README de open-data citado en #123.
3. API pública con `models=` fijado (mismas variables que la app):
   - `icon_seamless` / `icon_eu`: todo OK **salvo `uv_index_max` = null** (ICON no trae UV
     y no lo toma de GFS automáticamente).
   - `icon_global`: además `visibility` = null.
   - `gfs013`: `uv_index_max` OK. `meteofrance_currents`: `sea_level_height_msl` y
     corrientes OK. `meteofrance_wave`: olas OK.
   - Conclusión provisional: si `best_match` no responde en local, la app necesitaría
     **dos peticiones de clima** (`models=icon_seamless` + `models=gfs013` solo para
     `daily=uv_index_max`), porque pedir varios modelos a la vez renombra las variables
     (`temperature_2m_icon_seamless`...). En marino, `best_match` (`marine_best_match`)
     es la única forma de obtener olas + SST + corrientes + nivel del mar en una sola
     petición sin sufijos.

Pendiente (requiere Docker): si `best_match` responde en local, comparación local vs
pública (`-Comparar`), disco tras la sincronización y RAM.

## nginx delante de la API (caché, límite por IP y clave de la app)

Servicio `nginx` en `http://127.0.0.1:8081` (config en `nginx/default.conf.template`).
La API directa sigue en `:8080` solo para comparar. Qué hace:

- **Caché en disco** (`proxy_cache`, máx. 1 GB): guarda cada respuesta 30 min por URL.
- **`proxy_cache_lock`**: si llegan muchas peticiones iguales a la vez, solo una va a Open-Meteo.
- **`proxy_cache_use_stale`**: si Open-Meteo falla o está ocupado, sirve el último dato bueno.
- **Límite por IP**: 5 req/s con ráfaga de 20; si se pasa, responde 429.
- **Clave de la app**: exige la cabecera `X-Marante-Clave` (por defecto `prueba-local`;
  cambiarla con la variable de entorno `MARANTE_CLAVE`). Sin ella, 403.
- Solo expone `/v1/forecast`, `/v1/marine` y `/salud`; el resto da 404.

Probarlo (PowerShell), con los contenedores arrancados:

```powershell
$h = @{ 'X-Marante-Clave' = 'prueba-local' }
$u = 'http://127.0.0.1:8081/v1/forecast?latitude=43.37&longitude=-8.40&hourly=temperature_2m'
(Invoke-WebRequest $u -Headers $h).Headers['X-Cache-Status']   # 1.ª vez: MISS
(Invoke-WebRequest $u -Headers $h).Headers['X-Cache-Status']   # 2.ª vez: HIT
try { Invoke-WebRequest $u } catch { $_.Exception.Response.StatusCode }   # sin clave: Forbidden
docker exec marante-meteo-nginx nginx -t                        # valida la configuración
```
