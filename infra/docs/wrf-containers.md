# WRF Container Images

Dockerized builds of the Weather Research and Forecasting (WRF) model and the WRF Preprocessing System (WPS) for the WRFCoin weather data pipeline.

## Prerequisites

- Docker 20.10+ with BuildKit enabled
- At least 20 GB free disk space (WRF compilation produces large intermediate files)
- For geography data: an additional 3-30 GB depending on resolution (see Geography Data Setup below)

## Images

| Image | Dockerfile | Description | Approx. Size |
|-------|-----------|-------------|-------------|
| `wrfcoin/wps:4.5` | `Dockerfile.wps` | WPS with MPI support | ~500 MB |
| `wrfcoin/wrf:4.5.2` | `Dockerfile.wrf` | WRF-ARW dmpar (MPI) | ~1.5 GB |
| `wrfcoin/wrf-nano:4.5.2` | `Dockerfile.wrf-nano` | WRF serial, CI-optimized | ~2 GB |

The WRF-family Dockerfiles pin their Ubuntu base image and the upstream WRF/WPS
tarball SHA256 values by default. The current digest manifest lives in
[`wrf/SHA256SUMS.txt`](../docker/wrf/SHA256SUMS.txt).

## Building Images

```bash
cd infra/docker

# Build WPS
docker build -f Dockerfile.wps -t wrfcoin/wps:4.5 .

# Build WRF (takes 30-45 minutes)
docker build -f Dockerfile.wrf -t wrfcoin/wrf:4.5.2 .

# Build WRF nano for CI
docker build -f Dockerfile.wrf-nano -t wrfcoin/wrf-nano:4.5.2 .

# Or build both WPS and WRF via Compose
docker compose -f docker-compose.wrf.yml build
```

To build with a different WRF version:

```bash
docker build -f Dockerfile.wrf --build-arg WRF_VERSION=4.6 -t wrfcoin/wrf:4.6 .
```

## Running the WPS to WRF Pipeline

### 1. Prepare geography data

Download WPS geography data and mount it into the WPS container (see Geography Data Setup below).

### 2. Run WPS

```bash
# Start WPS container with geography data mounted
docker compose -f docker-compose.wrf.yml run wps

# Inside the container, run the WPS programs in order:
cp namelist.wps.sample namelist.wps   # or provide your own
./geogrid.exe
# Link GRIB input files, then:
./ungrib.exe
./metgrid.exe
```

### 3. Run WRF

```bash
# Start WRF container (WPS output is shared via the wps-output volume)
docker compose -f docker-compose.wrf.yml run wrf

# Inside the container:
cd /wrf/run
ln -sf /data/input/met_em* .
cp /wrf/run/namelist.input.sample namelist.input   # or provide your own
./real.exe
mpirun -np 4 ./wrf.exe
```

Output files (`wrfout_*`) will be in the `wrf-output` volume.

## Using the Nano Image for CI

The `wrf-nano` image is a serial (non-MPI) build designed for CI pipelines. It validates that WRF compiles and the executables are functional without requiring MPI infrastructure.

```bash
# Build and run healthcheck
docker build -f Dockerfile.wrf-nano -t wrfcoin/wrf-nano:4.5.2 .
docker run --rm wrfcoin/wrf-nano:4.5.2 -c "/usr/local/bin/healthcheck-wrf.sh --wrf"
```

The GitHub Actions workflow `.github/workflows/wrf-nano-ci.yml` automates this on every PR.

## Geography Data Setup

WPS requires static geography data (terrain, land use, soil type, etc.). Download from the WRF users page:

```bash
# Low resolution (~3 GB) — sufficient for testing
wget https://www2.mmm.ucar.edu/wrf/src/wps_files/geog_low_res_mandatory.tar.gz
tar xzf geog_low_res_mandatory.tar.gz

# Mount into Docker volume
docker volume create geog-data
docker run --rm -v geog-data:/data/geog -v $(pwd)/WPS_GEOG:/source \
    ubuntu:22.04 cp -r /source/. /data/geog/
```

For production runs, download the full resolution dataset (~30 GB) from the same source.

## Troubleshooting

### Build fails at configure step

The WRF and WPS configure scripts are interactive. The Dockerfiles pipe the correct option numbers. If building on a non-x86_64 architecture, the option numbers may differ. Check `./configure` interactively to find the correct option for your platform:
- WRF dmpar gfortran: typically option 34 on x86_64 Linux
- WRF serial gfortran: typically option 32 on x86_64 Linux
- WPS gfortran serial: typically option 1

### Build fails with missing NetCDF

Ensure `NETCDF`, `HDF5`, `JASPERLIB`, and `JASPERINC` environment variables point to the correct library paths. The Dockerfiles set these to `/usr` which is correct for Ubuntu package installs.

### WRF runs out of memory

The sample namelist uses a 50x50 grid at 10 km resolution, which is small. For larger domains, increase the container's memory limit:

```bash
docker run --memory=8g ...
```

### Permission errors on volumes

Ensure the data directories inside the container (`/data/geog`, `/data/input`, `/data/output`) are writable. The Dockerfiles create these with default permissions. If running as a non-root user, adjust permissions accordingly.

### Slow compilation

WRF compilation is CPU-intensive and takes 30-45 minutes. Use Docker BuildKit caching to avoid rebuilding unchanged layers:

```bash
DOCKER_BUILDKIT=1 docker build -f Dockerfile.wrf -t wrfcoin/wrf:4.5.2 .
```
