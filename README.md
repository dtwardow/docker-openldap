# OpenLDAP-Server #

An **OpenLDAP-Server** to provide user authentication including password policies for Linux.

The intention is to provide an auto-configured LDAP authentication-server for other containers.
Other containers should use **nslcd** for user-authentication.

NOTE: On purpose, there is no secured channel (TLS/SSL), because this service should never be exposed to the internet, but only be used directly
by other Docker containers using Docker's `link` option.


## Requirements ##

- Docker (>= 1.9.0)

## Provided Resouces ##

The service provides the following network ports and filesystems.

### Exposed Ports ###

- `389` : LDAP-Server (internal)
- `10389` : LDAP-Server (external)

### Exposed Filesystems ###

None


## Build Image ##

The image is build by executing the following Docker-Command in the project's root directory:

    docker build -t openldap \
           --build-arg='HTTP_PROXY=http://<proxy-hostname>:<port>' \
           .

### Build Arguments ###

- `HTTP_PROXY=http://<proxy-hostname>:<proxy-port>`
  - This Web-Proxy is just required for the installation process. It is no more used afterwards.

> Build Arguments can also be provided in the `Dockerfile` using the `ARG`-instruction.

## Usage ##

The created container is configured automatically by the `entrypoint`-script during the **first** run.

During this **first** run the following environment variables **must** be provided:

- `SLAPD_DOMAIN`
  - LDAP-Domain for project-database
  - Provide in dotted (`.`) notation (i.e. domain.com)
- `SLAPD_PASSWORD`
  - Administrator Password for Project- and Config-Database
- `SLAPD_ORGANIZATION` *(optional)*
  - Defaults to `$SLAPD_DOMAIN`
- `SLAPD_MULTIMASTER_HOSTS` *(optional)*
  - Configure **N-Way Multi-Master Replication** with other LDAP-Servers
  - Syntax: `"<Serer-URI>|<Admin-Password>[,...]"`

Afterwards, the variables are no more used.

### Startup ###

The container can be started directly (in background) by the following command-line:

    docker run --name ldapauth -d \
               -p 10389:389 \
               -e SLAPD_PASSWORD=<secret> \
               -e SLAPD_DOMAIN=<example.org> \
               -e SLAPD_MULTIMASTER_HOSTS="ldap://<hostname-other-ldap>:<port>|<other-ldap-admin-password>,..." \
               openldap

Alternatively it can be started in a `docker-compose` context with the following configuration parameters:

    ldap:
        image: openldap:latest
        container_name: ldapauth
        hostname: <hostname>
        domainname: <domain>
        ports:
            - 10389:389
        environment:
            - SLAPD_DOMAIN=<ldap-domain>
            - SLAPD_PASSWORD=<secret>
            - SLAPD_MULTIMASTER_HOSTS="ldap://<hostname-other-ldap>:<port>|<other-ldap-admin-password>,..."

### Shell Access ###

For debugging and maintenance purposes you may want access the containers shell. A running containers shell can be started as follows:

    docker exec -it ldapauth bash

### Logging ###

Logging is performed directly in the console.

With installed **ldaputils** the system can be debugged.

### Data Persistence ###

The image exposes two directories (`VOLUME ["/etc/ldap", "/var/lib/ldap"]`).
The first holds the "static" configuration while the second holds the actual
database. Please make sure that these two directories are saved (in a data-only
container or alike) in order to make sure that everything is restored after a
restart of the container.
