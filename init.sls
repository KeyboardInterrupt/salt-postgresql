{% set version = pillar['postgresql']['version']|default('10') %}
{% set pg_config = pillar['postgresql']['config']|default({}) %}
{% set max_connections = pg_config['max_connections']|default(100) %}

# Install postgresql
postgresql:
  pkg.installed:
     - pkgs: [postgresql-{{ version }}]
  service.running:
    - enable: true
    - reload: {{ pillar['postgresql']['reload']|default('true') }}
    - watch:
      - file: /etc/postgresql/{{ version }}/main/*

# Install additional custom packages
{% if pillar['postgresql']['additional_dependencies'] is defined %}
postgresql_additional_dependencies:
  pkg.installed:
    - pkgs: {{ pillar['postgresql']['additional_dependencies'] }}
{% endif %}

# Make sure data directory is owned by postgres (necessary when using seperate mountpoint)
chown_pgdata:
  file.directory:
    - name: /var/lib/postgresql
    - user: postgres
    - group: postgres

# Deploy configuration
/etc/postgresql/{{ version }}/main/postgresql.conf:
  file.managed:
    - require:
      - pkg: postgresql
    - mode: 644
    - user: postgres
    - group: postgres
    - source: salt://{{ slspath }}/postgresql.conf.jinja
    - template: jinja
    - defaults:
      # These are the defaults, which can be overridden by pillars
      version: {{ version }}
      listen_addresses: ''
      max_connections: {{ max_connections }}
      work_mem: {{ (grains['mem_total'] * 0.9 / max_connections)|int }}MB
      shared_buffers: {{ (grains['mem_total'] * 0.1)|int }}MB
      maintenance_work_mem: {{ (grains['mem_total'] / 1024 * 50)|int }}MB
      effective_cache_size: {{ (grains['mem_total'] * 0.8)|int }}MB
      wal_level: replica
      wal_log_hints: false
      max_wal_senders: 5 # NOTE: Since postgresql-10, the default is 10
    - context:
      # Override defaults from pillar configuration
{% for var in [
  'listen_addresses', 'work_mem', 'shared_buffers', 'maintenance_work_mem',
  'effective_cache_size', 'archive_command', 'wal_level', 'wal_log_hints', 'max_wal_senders',
  'wal_keep_segments', 'wal_buffers'
  ] %}
  {% if pg_config[var] is defined %}
      {{ var }}: {{ pg_config[var] }}
  {% endif %}
{% endfor %}

/etc/postgresql/{{ version }}/main/pg_hba.conf:
  file.managed:
    - mode: 640
    - user: postgres
    - group: postgres
    - source: salt://{{ slspath }}/pg_hba.conf.jinja
    - template: jinja
    - require:
      - pkg: postgresql

# Deploy users. Sort them, so order is not changing between salt runs
{% for config in pillar['postgresql']['users'] %}
createuser-{{ loop.index }}:
  cmd.run:
    - name: psql -t -c "CREATE ROLE {{ config['username'] }} {{ config['options']|default('NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT LOGIN') }};"
    - unless: psql -t -c "SELECT 1 FROM pg_roles WHERE rolname='{{ config['username'] }}'" |grep -q 1
    - runas: postgres

# The "replication" keyword is not a real database, but just used for permissions in pg_hba.conf
{% if config['database'] != "replication" %}
createdb-{{ loop.index }}:
  cmd.run:
    - name: psql -t -c "CREATE DATABASE {{ config['database'] }} OWNER {{ config['username'] }};"
    - unless: psql -t -c "SELECT 1 FROM pg_database WHERE datname='{{ config['database'] }}'" |grep -q 1
    - runas: postgres
    - require:
      - cmd: createuser-{{ loop.index }}
{% endif %}
{% endfor %}
