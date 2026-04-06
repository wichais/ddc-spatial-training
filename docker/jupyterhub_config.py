# ===========================================================================
# JupyterHub Configuration for DDC Training (40 Trainees)
# ===========================================================================
# - 40 trainee accounts (trainee01 - trainee40)
# - 1 instructor account with admin privileges
# - Each user gets isolated Jupyter container (DockerSpawner)
# - Resource limits: 2 CPU cores, 2GB RAM per user
# - Shared Vertica database connection
# ===========================================================================

import os
import sys

# ===========================================================================
# Basic Configuration
# ===========================================================================
c.JupyterHub.ip = '0.0.0.0'
c.JupyterHub.port = 8000
c.JupyterHub.hub_ip = '0.0.0.0'
c.JupyterHub.hub_connect_ip = 'ddc-jupyterhub'

c.JupyterHub.db_url = 'sqlite:////srv/jupyterhub/data/jupyterhub.sqlite'
c.JupyterHub.cookie_secret_file = '/srv/jupyterhub/data/jupyterhub_cookie_secret'

# ===========================================================================
# User Authentication (DummyAuthenticator for training)
# ===========================================================================
c.JupyterHub.authenticator_class = 'dummy'

trainees = [f'trainee{i:02d}' for i in range(1, 41)]
c.Authenticator.allowed_users = set(trainees + ['instructor'])
c.Authenticator.admin_users = {'instructor'}
c.DummyAuthenticator.password = "trainee123"

# ===========================================================================
# Docker Spawner
# ===========================================================================
c.JupyterHub.spawner_class = 'dockerspawner.DockerSpawner'

c.DockerSpawner.network_name = os.environ.get('DOCKER_NETWORK_NAME', 'ddc-training-net')
c.DockerSpawner.image = 'courses-trainee:latest'
c.DockerSpawner.remove = True
c.DockerSpawner.name_template = 'jupyter-{username}'

# Resource limits per user
c.DockerSpawner.cpu_limit = 2.0
c.DockerSpawner.mem_limit = '2G'
c.DockerSpawner.cpu_guarantee = 0.5
c.DockerSpawner.mem_guarantee = '512M'

# ===========================================================================
# Volume Mounts
# ===========================================================================
# DockerSpawner mounts from the Docker HOST, not from the JupyterHub container.
# On Docker Desktop (Windows/Mac), host paths must be shared in Docker settings.
#
# HOST_COURSE_PATH should be set to the host path of the courses/ directory.
# e.g. /d/OneDrive/.../courses  (Docker Desktop uses /d/ for D:\)

HOST_PATH = os.environ.get('HOST_COURSE_PATH', '')

if HOST_PATH:
    c.DockerSpawner.volumes = {
        'jupyterhub-user-{username}': '/home/jovyan/work',
        f'{HOST_PATH}/course_1': {'bind': '/home/jovyan/course_1', 'mode': 'ro'},
        f'{HOST_PATH}/course_2': {'bind': '/home/jovyan/course_2', 'mode': 'ro'},
        f'{HOST_PATH}/workshop': {'bind': '/home/jovyan/workshop', 'mode': 'ro'},
        f'{HOST_PATH}/ddc_helpers.py': {'bind': '/home/jovyan/ddc_helpers.py', 'mode': 'ro'},
    }
else:
    # Fallback: only persistent work volume (no shared materials)
    c.DockerSpawner.volumes = {
        'jupyterhub-user-{username}': '/home/jovyan/work',
    }
    print("WARNING: HOST_COURSE_PATH not set. Trainees won't see course notebooks.")

# ===========================================================================
# Environment Variables (Vertica Connection)
# ===========================================================================
c.DockerSpawner.environment = {
    'PYTHONPATH': '/home/jovyan',
    'VERTICA_HOST': os.environ.get('VERTICA_HOST', 'ddc-vertica'),
    'VERTICA_PORT': os.environ.get('VERTICA_PORT', '5433'),
    'VERTICA_USER': os.environ.get('VERTICA_USER', 'dbadmin'),
    'VERTICA_PASSWORD': os.environ.get('VERTICA_PASSWORD', ''),
    'VERTICA_DATABASE': os.environ.get('VERTICA_DATABASE', 'VMart'),
    'VERTICA_SCHEMA': os.environ.get('VERTICA_SCHEMA', 'ddc_training'),
    'JUPYTER_ENABLE_LAB': 'yes',
}

# ===========================================================================
# Notebook Command
# ===========================================================================
# Don't set DockerSpawner.cmd — let it use jupyterhub-singleuser from the image
c.Spawner.default_url = '/lab'

# ===========================================================================
# Timeouts
# ===========================================================================
c.DockerSpawner.start_timeout = 120
c.DockerSpawner.http_timeout = 60

# Idle culler: shut down after 2 hours idle
c.JupyterHub.services = [
    {
        'name': 'idle-culler',
        'admin': True,
        'command': [
            sys.executable,
            '-m', 'jupyterhub_idle_culler',
            '--timeout=7200'
        ]
    }
]

# ===========================================================================
# Admin & Limits
# ===========================================================================
c.JupyterHub.admin_access = True
c.JupyterHub.log_level = 'INFO'
c.JupyterHub.concurrent_spawn_limit = 10

# ===========================================================================
# Welcome Message
# ===========================================================================
c.JupyterHub.template_vars = {
    'announcement': '''
    <div class="alert alert-info">
        <h4>Welcome to DDC Spatial Epidemiology Training!</h4>
        <p><b>Course 1:</b> Open <code>course_1/notebooks/00_workshop_runner.ipynb</code></p>
        <p><b>Slides:</b> Open <code>course_1/notebooks/00_slides.ipynb</code></p>
        <p>Your work is saved in <code>work/</code> (persistent across sessions)</p>
    </div>
    '''
}

print("=" * 70)
print("JupyterHub Config Loaded")
print(f"  Trainees: {len(trainees)} accounts (trainee01 - trainee40)")
print(f"  Admin: instructor")
print(f"  Network: {c.DockerSpawner.network_name}")
print(f"  Image: {c.DockerSpawner.image}")
print(f"  HOST_COURSE_PATH: {HOST_PATH or '(NOT SET)'}")
print("=" * 70)
