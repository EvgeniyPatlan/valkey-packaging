# Hardened Valkey Docker Image

A security-hardened Docker image for Valkey built from Percona DEB packages.

## Prerequisites

- Docker 20.10+
- Docker Compose 1.29+
- Valkey DEB package (e.g., `valkey_9.0.2-1.trixie_amd64.deb`)

## Quick Start

1. **Place your DEB package** in this directory
   ```bash
   cp /path/to/valkey-*.deb .
   ```

2. **Build the image**
   ```bash
   make build
   ```

3. **Run the container**
   ```bash
   make run
   ```

4. **Test the installation**
   ```bash
   make test
   ```

## Files Description

- **Dockerfile.hardened** - Multi-stage hardened Dockerfile
- **docker-entrypoint.sh** - Enhanced entrypoint with env var support
- **docker-compose.yml** - Development configuration
- **docker-compose.prod.yml** - Production configuration with password
- **.env.example** - Environment variable template
- **valkey-custom.conf.example** - Advanced config example (optional)
- **seccomp-valkey.json** - Seccomp security profile
- **Makefile** - Build automation
- **.dockerignore** - Files to exclude from build context

## Security Model (How it Works Without Password)

The image follows the official Valkey/Redis security model:

**Development (No Password):**
- Safe by default: Valkey enables **protected-mode** automatically
- Protected-mode blocks external connections when no password is set
- Only localhost can connect without authentication
- Perfect for development and testing

**Production (With Password):**
- Set `VALKEY_PASSWORD` environment variable
- Protected-mode allows external connections when password is set
- All connections require authentication

## Configuration Options

You have **three ways** to configure Valkey (from simplest to most complex):

### Option 1: Default Package Config (Simplest - for Development)

### Option 1: Default Package Config (Simplest - for Development)

Just build and run - uses package defaults with protected-mode:
```bash
make build
make run
```

✅ No password required (protected-mode enabled)
✅ Only localhost can connect
✅ Perfect for development

### Option 2: Environment Variables (Recommended for Production)

Set password and other settings via environment variables:

1. **Create `.env` file:**
   ```bash
   cp .env.example .env
   ```

2. **Edit `.env` with your settings:**
   ```bash
   VALKEY_PASSWORD=MyStr0ng!P@ssw0rd123
   VALKEY_MAXMEMORY=1gb
   ```

3. **Run with production compose:**
   ```bash
   docker-compose -f docker-compose.prod.yml up -d
   ```

✅ Password set securely via environment variable
✅ No config file editing needed
✅ Easy to use with secrets management

**Available environment variables:**
- `VALKEY_PASSWORD` - Set requirepass (no password if empty)
- `VALKEY_MAXMEMORY` - Set max memory (e.g., 512mb, 2gb)
- `VALKEY_BIND` - Set bind address (default from package)

### Option 3: Custom Configuration File (Most Control)

### Option 3: Custom Configuration File (Most Control)

For advanced configurations (rename commands, AOF settings, etc.):

1. **Create custom config:**
   ```bash
   cp valkey-custom.conf.example valkey.conf
   ```

2. **Edit with advanced security settings:**
   ```conf
   requirepass YOUR_STRONG_PASSWORD
   rename-command FLUSHDB ""
   rename-command FLUSHALL ""
   maxmemory 2gb
   appendonly yes
   ```

3. **Enable in docker-compose.yml:**
   ```yaml
   volumes:
     - ./valkey.conf:/etc/valkey/valkey.conf:ro
   
   command: ["valkey-server", "/etc/valkey/valkey.conf"]
   ```

4. **Build and run:**
   ```bash
   make build
   make run
   ```

 Full control over all Valkey settings
 Can rename/disable dangerous commands
 Best for complex production scenarios

## Quick Start Examples

### Development (No Password)
```bash
# Just build and run
cp /path/to/valkey_*.deb .
make build
make run

# Connect without password
docker exec -it valkey-hardened valkey-cli ping
```

### Production (With Password via Environment Variable)
```bash
# Create .env file
echo "VALKEY_PASSWORD=MySecurePassword123" > .env

# Run production setup
docker-compose -f docker-compose.prod.yml up -d

# Connect with password
docker exec -it valkey-prod valkey-cli -a MySecurePassword123 ping
```

### Production (With Custom Config File)
```bash
# Create and edit config
cp valkey-custom.conf.example valkey.conf
# Edit valkey.conf with your settings

# Uncomment config mount in docker-compose.yml
# Then build and run
make build
make run
```

## Security Features

Non-root user (uid=999)
Read-only root filesystem
Dropped capabilities (only essential ones kept)
Seccomp profile for syscall filtering
No-new-privileges security option
Resource limits (CPU, memory, PIDs)
Minimal base image (Debian Trixie Slim)
Removed setuid/setgid binaries
Health checks enabled
SBOM generation
Uses package maintainer's default configuration

### Adjust Resource Limits

Edit `docker-compose.yml` to modify CPU/memory limits:
```yaml
deploy:
  resources:
    limits:
      cpus: '2.0'
      memory: 1G
```

### Network Configuration

By default, Valkey in the package may bind to all interfaces. For security in production:

1. **Create custom config** (if not already done):
   ```bash
   cp valkey-custom.conf.example valkey.conf
   ```

2. **Edit `valkey.conf`** to bind only to specific IPs:
   ```conf
   bind 127.0.0.1 ::1  # localhost only
   ```

3. **Or expose to other hosts** (use with caution):
   ```conf
   bind 0.0.0.0 ::
   ```

4. **Update docker-compose.yml** port binding:
   ```yaml
   ports:
     - "6379:6379"  # Exposed to all interfaces
   ```

## Makefile Targets

```bash
make build    # Build the Docker image
make run      # Start Valkey container
make stop     # Stop the container
make logs     # View container logs
make test     # Run basic tests
make clean    # Remove everything
make all      # Build and test
make help     # Show available targets
```

## Manual Docker Commands

### Build
```bash
docker build -t percona/valkey:9.0.2-hardened -f Dockerfile.hardened .
```

### Run with security options
```bash
docker run -d \
  --name valkey \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  --cap-add CHOWN --cap-add SETGID --cap-add SETUID \
  --read-only \
  -v valkey-data:/data \
  -p 127.0.0.1:6379:6379 \
  percona/valkey:9.0.2-hardened
```

### Connect to Valkey
```bash
docker exec -it valkey valkey-cli
```

## Troubleshooting

### Container won't start
Check logs:
```bash
docker-compose logs valkey
```

### Can't connect to Valkey
**Without password (development):**
```bash
docker-compose ps
docker exec -it valkey-hardened valkey-cli ping
```

**With password (production):**
```bash
docker exec -it valkey-prod valkey-cli -a YOUR_PASSWORD ping
```

### "NOAUTH Authentication required" error
You need to provide the password:
```bash
# Check if password is set
docker exec -it valkey-hardened valkey-cli -a YOUR_PASSWORD CONFIG GET requirepass

# Or connect interactively
docker exec -it valkey-hardened valkey-cli
> AUTH YOUR_PASSWORD
> PING
```

### Permission errors
Ensure data directory has correct permissions:
```bash
docker-compose down
docker volume rm valkey-data
docker-compose up -d
```

### "DENIED" errors when connecting remotely
This is **protected-mode** working correctly! Without a password, Valkey only allows localhost connections.

**To fix (choose one):**
1. **Set a password** (recommended):
   ```bash
   echo "VALKEY_PASSWORD=YourPassword" > .env
   docker-compose -f docker-compose.prod.yml up -d
   ```

2. **Or connect from localhost only**:
   ```bash
   # SSH to the server first, then connect
   docker exec -it valkey-hardened valkey-cli
   ```

### Check protected-mode status
```bash
docker exec -it valkey-hardened valkey-cli CONFIG GET protected-mode
```

## Testing Security

```bash
# Verify non-root user
docker run --rm percona/valkey:9.0.2-hardened id

# Verify dropped capabilities
docker run --rm --cap-drop=ALL percona/valkey:9.0.2-hardened valkey-cli --version

# Check setuid binaries
docker run --rm percona/valkey:9.0.2-hardened find / -perm /6000 -type f 2>/dev/null
```
