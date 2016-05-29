#!/bin/bash

# When not limiting the open file descritors limit, the memory consumption of
# slapd is absurdly high. See https://github.com/docker/docker/issues/8231
ulimit -n 8192

set -e


if [[ ! -d ${CONFIG_DIR}/slapd.d ]]; then
    # ENV: LDAP Password
    if [[ -z "$SLAPD_PASSWORD" ]]; then
        echo -n >&2 "Error: Container not configured and SLAPD_PASSWORD not set. "
        echo >&2 "Did you forget to add -e SLAPD_PASSWORD=... ?"
        exit 1
    fi
    
    # ENV: Configuration admin password equals domain admin!
    SLAPD_CONFIG_PASSWORD=${SLAPD_PASSWORD}

    # ENV: LDAP Domain
    if [[ -z "$SLAPD_DOMAIN" ]]; then
        echo -n >&2 "Error: Container not configured and SLAPD_DOMAIN not set. "
        echo >&2 "Did you forget to add -e SLAPD_DOMAIN=... ?"
        exit 1
    fi

    # ENV: Organization meta-info
    SLAPD_ORGANIZATION="${SLAPD_ORGANIZATION:-${SLAPD_DOMAIN}}"

    # Copy distribution data to recreate LDAP-config
    cp -a ${CONFIG_DIR}.dist/* ${CONFIG_DIR}

    # Include LDAP-scehma for Samba-Account (Debian-bug)
    zcat /usr/share/doc/samba-doc/examples/LDAP/samba.schema.gz > ${CONFIG_DIR}/schema/samba.schema

    cat <<-EOF | debconf-set-selections
        slapd slapd/no_configuration boolean false
        slapd slapd/password1 password $SLAPD_PASSWORD
        slapd slapd/password2 password $SLAPD_PASSWORD
        slapd shared/organization string $SLAPD_ORGANIZATION
        slapd slapd/domain string $SLAPD_DOMAIN
        slapd slapd/backend select HDB
        slapd slapd/allow_ldap_v2 boolean false
        slapd slapd/purge_database boolean false
        slapd slapd/move_old_database boolean true
EOF

    dpkg-reconfigure -f noninteractive slapd >/dev/null 2>&1

    # Regenerate all Schemas
    echo "Re-generate LDIFs from Schema files (ensures we've included all schemas) ..."
    mkdir -p /tmp/ldap-schemas
    rm -f ${CONFIG_DIR}/slapd.d/cn=config/cn=schema/*
    slaptest -f /tmp/schemas.startup.conf -F /tmp/ldap-schemas
    mv /tmp/ldap-schemas/cn=config/cn=schema/* ${CONFIG_DIR}/slapd.d/cn=config/cn=schema

    dc_string=""
    IFS="."; declare -a dc_parts=($SLAPD_DOMAIN)
    for dc_part in "${dc_parts[@]}"; do
        dc_string="$dc_string,dc=$dc_part"
    done
    base_string="BASE ${dc_string:1}"

    sed -i "s/^#BASE.*/${base_string}/g" ${CONFIG_DIR}/ldap.conf

    if [[ -n "${SLAPD_CONFIG_PASSWORD}" ]]; then
        password_hash=`slappasswd -s "${SLAPD_CONFIG_PASSWORD}"`

        sed_safe_password_hash=${password_hash//\//\\\/}

        slapcat -n0 -F ${CONFIG_DIR}/slapd.d -l /tmp/config.ldif
        sed -i "s/\(olcRootDN: cn=admin,cn=config\)/\1\nolcRootPW: ${sed_safe_password_hash}/g" /tmp/config.ldif
        rm -rf ${CONFIG_DIR}/slapd.d/*
        slapadd -n0 -F ${CONFIG_DIR}/slapd.d -l /tmp/config.ldif >& /dev/null
    fi

    echo "Load all modules not included by default ..."
    for module in ${CONFIG_DIR}/modules/*.ldif; do
        echo -n "  $(basename ${module})"
        slapadd -n0 -F ${CONFIG_DIR}/slapd.d -l "${module}" >& /dev/null
        echo " [$?]"
    done

    if [[ -n "${SLAPD_MULTIMASTER_HOSTS}" ]]; then
        echo "Setup N-Way Multi-Master-Replication ..."
        IFS=","; declare -a hosts=($SLAPD_MULTIMASTER_HOSTS)
        COUNTER=1

        echo "  -> Add Hosts ..."
        echo "     [Idx] [RID (config / ${SLAPD_DOMAIN})] @ [LDAP URL] ([used password])"
        echo "     ---------------------------------------------------------------------"
        slapcat -n0 -F ${CONFIG_DIR}/slapd.d -l /tmp/config.ldif
        for host in "${hosts[@]}"; do
            IFS="|"; declare -a parts=($host)

            RID_PROD=$(printf '%03d' $((${COUNTER} + 100)))
            RID_CONFIG=$(printf '%03d' $((${COUNTER} + 200)))
            SERVER_URL=${parts[0]}
            SERVER_PASSWORD=${parts[1]}

            echo "     [${COUNTER}] ${RID_CONFIG}/${RID_PROD} @ ${SERVER_URL} (${SERVER_PASSWORD})"

            # Add ServerID (required for identification)
            sed -i -e "/cn: config/{:a;n;/$/!ba;a\\olcServerID: ${COUNTER} ${SERVER_URL}" -e "}" /tmp/config.ldif

            # Add sync for Config-Database (RID > 0)
            sed -i -e "/olcDatabase: {0}config/ a olcSyncRepl: rid=${RID_CONFIG} provider=\"${SERVER_URL}\" binddn=\"cn=admin,cn=config\" bindmethod=simple credentials=${SERVER_PASSWORD} searchbase=\"cn=config\" type=refreshAndPersist retry=\"5 +\" timeout=1" /tmp/config.ldif

            # Add sync for productive data (RID > 100)
            sed -i -e "/olcDatabase: {1}hdb/ a olcSyncRepl: rid=${RID_PROD} provider=\"${SERVER_URL}\" binddn=\"cn=admin,${dc_string:1}\" bindmethod=simple credentials=${SERVER_PASSWORD} searchbase=\"${dc_string:1}\" schemachecking=off type=refreshAndPersist retry=\"5 +\" timeout=1" /tmp/config.ldif

            COUNTER=$(($COUNTER + 1))
        done

        echo "  -> Add additional parameters to directory"
        sed -i -e "/olcDatabase: {1}hdb/ a olcMirrorMode: TRUE" /tmp/config.ldif
        sed -i -e "/olcDatabase: {0}config/ a olcMirrorMode: TRUE" /tmp/config.ldif

        cat <<-EOF >> /tmp/config.ldif
dn: olcOverlay=syncprov,olcDatabase={0}config,cn=config
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov

dn: olcOverlay=syncprov,olcDatabase={1}hdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
EOF

        echo -n "  -> Push everything to server"
        rm -rf ${CONFIG_DIR}/slapd.d/*
        slapadd -n0 -F ${CONFIG_DIR}/slapd.d -l /tmp/config.ldif >& /dev/null
        echo " [$?]"
    fi

    if [[ -n "$SLAPD_ADDITIONAL_SCHEMAS" ]]; then
        IFS=","; declare -a schemas=($SLAPD_ADDITIONAL_SCHEMAS)

        for schema in "${schemas[@]}"; do
            echo "Load additional schema: ${schema}"
            slapadd -n0 -F ${CONFIG_DIR}/slapd.d -l "${CONFIG_DIR}/schema/${schema}.ldif"
        done
    fi

    # Required schema updates for SAMBA
    slapcat -n0 -F ${CONFIG_DIR}/slapd.d -l /tmp/config.ldif
    sed -i -e "/olcDatabase: {1}hdb/ a olcDbIndex: entryCSN eq" /tmp/config.ldif
    sed -i -e "/olcDatabase: {1}hdb/ a olcDbIndex: entryUUID eq" /tmp/config.ldif
    sed -i -e "/olcDatabase: {1}hdb/ a olcDbIndex: sambaDomainName eq" /tmp/config.ldif
    sed -i -e "/olcDatabase: {1}hdb/ a olcDbIndex: sambaSID eq" /tmp/config.ldif
    sed -i -e "/olcDatabase: {1}hdb/ a olcDbIndex: ou eq" /tmp/config.ldif
    #sed -i -e "s/olcAccess: {\([0-9]*\)}.*dn\.base\=.*/olcAccess: {\1}to dn.subtree=\"${dc_string:1}\" by self write by anonymous auth by * search by * read/g" /tmp/config.ldif
    rm -rf ${CONFIG_DIR}/slapd.d/*
    slapadd -n0 -F ${CONFIG_DIR}/slapd.d -l /tmp/config.ldif
else
    slapd_configs_in_env=`env | grep 'SLAPD_'`

    if [ -n "${slapd_configs_in_env:+x}" ]; then
        echo "Info: Container already configured, therefore ignoring SLAPD_xxx environment variables"
    fi
fi

# Reset file and directory permissions on every startup
chown -R openldap:openldap ${DATA_DIR} /var/run/slapd/ ${CONFIG_DIR}

echo "Starting OpenLDAP Directory Server ..."
exec "$@"

