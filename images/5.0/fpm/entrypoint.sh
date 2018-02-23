#!/bin/bash
set -e

# version_greater A B returns whether A > B
function version_greater() {
	[[ "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1" ]];
}

# return true if specified directory is empty
function directory_empty() {
	[ -n "$(find "$1"/ -prune -empty)" ]
}

function run_as() {
	if [[ $EUID -eq 0 ]]; then
		su - www-data -s /bin/bash -c "$1"
	else
		bash -c "$1"
	fi
}


usermod -u $WWW_USER_ID www-data
groupmod -g $WWW_GROUP_ID www-data

if [ ! -d /var/www/documents ]; then
	mkdir /var/www/documents
fi

chown -R www-data:www-data /var/www


if [ ! -f /usr/local/etc/php/php.ini ]; then
	cat <<EOF > /usr/local/etc/php/php.ini
date.timezone = ${PHP_INI_DATE_TIMEZONE}
sendmail_path = /usr/sbin/sendmail -t -i
EOF
fi

# Create a default config
if [ ! -f /usr/src/dolibarr/htdocs/conf/conf.php ]; then
	cat <<EOF > /usr/src/dolibarr/htdocs/conf/conf.php
<?php
// Config file for Dolibarr ${DOLI_VERSION}

// ###################
// # Main parameters #
// ###################
\$dolibarr_main_url_root='${DOLI_URL_ROOT}';
\$dolibarr_main_document_root='/var/www/html';
\$dolibarr_main_url_root_alt='/custom';
\$dolibarr_main_document_root_alt='/var/www/html/custom';
\$dolibarr_main_data_root='/var/www/documents';
\$dolibarr_main_db_host='${DOLI_DB_HOST}';
\$dolibarr_main_db_port='${DOLI_DB_PORT}';
\$dolibarr_main_db_name='${DOLI_DB_NAME}';
\$dolibarr_main_db_prefix='${DOLI_DB_PREFIX}';
\$dolibarr_main_db_user='${DOLI_DB_USER}';
\$dolibarr_main_db_pass='${DOLI_DB_PASSWORD}';
\$dolibarr_main_db_type='${DOLI_DB_TYPE}';
\$dolibarr_main_db_character_set='utf8';
\$dolibarr_main_db_collation='utf8_unicode_ci';

// ##################
// # Login		    #
// ##################
\$dolibarr_main_authentication='${DOLI_AUTH}';
\$dolibarr_main_auth_ldap_host='${DOLI_LDAP_HOST}';
\$dolibarr_main_auth_ldap_port='${DOLI_LDAP_PORT}';
\$dolibarr_main_auth_ldap_version='${DOLI_LDAP_VERSION}';
\$dolibarr_main_auth_ldap_servertype='${DOLI_LDAP_SERVERTYPE}';
\$dolibarr_main_auth_ldap_login_attribute='${DOLI_LDAP_LOGIN_ATTRIBUTE}';
\$dolibarr_main_auth_ldap_dn='${DOLI_LDAP_DN}';
\$dolibarr_main_auth_ldap_filter ='${DOLI_LDAP_FILTER}';
\$dolibarr_main_auth_ldap_admin_login='${DOLI_LDAP_ADMIN_LOGIN}';
\$dolibarr_main_auth_ldap_admin_pass='${DOLI_LDAP_ADMIN_PASS}';
\$dolibarr_main_auth_ldap_debug='${DOLI_LDAP_DEBUG}';

// ##################
// # Security	    #
// ##################
\$dolibarr_main_prod='${DOLI_PROD}';
\$dolibarr_main_force_https='${DOLI_HTTPS}';
\$dolibarr_main_restrict_os_commands='mysqldump, mysql, pg_dump, pgrestore';
\$dolibarr_nocsrfcheck='0';
\$dolibarr_main_cookie_cryptkey='$(openssl rand -hex 32)';
\$dolibarr_mailing_limit_sendbyweb='0';
EOF

	chown www-data:www-data /usr/src/dolibarr/htdocs/conf/conf.php
	chmod 755 /usr/src/dolibarr/htdocs/conf/conf.php
fi

# Detect installed version (docker specific solution)
installed_version="0.0.0~unknown"
if [ -f /var/www/documents/install.version ]; then
	installed_version=$(cat /var/www/documents/install.version)
fi
image_version=${DOLI_VERSION}

if version_greater "$installed_version" "$image_version"; then
	echo "Can't start Dolibarr because the version of the data ($installed_version) is higher than the docker image version ($image_version) and downgrading is not supported. Are you sure you have pulled the newest image version?"
	exit 1
fi

# Initialize image
if version_greater "$image_version" "$installed_version"; then
	echo "Dolibarr initialization..."
	if [[ $EUID -eq 0 ]]; then
		rsync_options="-rlDog --chown www-data:root"
	else
		rsync_options="-rlD"
	fi

	#cp -r /usr/src/dolibarr/scripts /var/www/
	rsync $rsync_options --delete --exclude /conf/ --exclude /custom/ --exclude /modulebuilder/ --exclude /theme/ /usr/src/dolibarr/htdocs/ /var/www/html/

	for dir in conf custom modulebuilder theme; do
		if [ ! -d /var/www/html/"$dir" ] || directory_empty /var/www/html/"$dir"; then
			rsync $rsync_options --include /"$dir"/ --exclude '/*' /usr/src/dolibarr/htdocs/ /var/www/html/
		fi
	done

	# Call upgrade scripts if needed
	# https://wiki.dolibarr.org/index.php/Installation_-_Upgrade#With_Dolibarr_.28standard_.zip_package.29
	if [ "$installed_version" != "0.0.0~unknown" ]; then
		echo "Dolibarr upgrade from $installed_version to $image_version..."

		if [ -f /var/www/documents/install.lock ]; then
			rm /var/www/documents/install.lock
		fi

		base_version=(${installed_version//./ })
		target_version=(${image_version//./ })

		run_as "php upgrade.php ${base_version[0]}.${base_version[1]}.0 ${target_version[0]}.${target_version[1]}.0" > /tmp/output1.html
		run_as "php upgrade2.php ${base_version[0]}.${base_version[1]}.0 ${target_version[0]}.${target_version[1]}.0" > /tmp/output2.html
		run_as "php step5.php ${base_version[0]}.${base_version[1]}.0 ${target_version[0]}.${target_version[1]}.0" > /tmp/output3.html

		rm -f /tmp/output1.html /tmp/output2.html /tmp/output3.html

		echo 'This is a lock file to prevent use of install pages' > /var/www/documents/install.lock
		chown www-data:www-data /var/www/documents/install.lock
		chmod 400 /var/www/documents/install.lock
	else
		# Create forced values for first install
		if [ ! -f /var/www/html/install/install.forced.php ]; then
			cat <<EOF > /var/www/html/install/install.forced.php
<?php
\$force_install_nophpinfo = true;
\$force_install_noedit = 2;
\$force_install_message = 'Dolibarr installation';
\$force_install_main_data_root = '/var/www/documents';
\$force_install_mainforcehttps = ${DOLI_HTTPS} == 1;
\$force_install_database = '${DOLI_DB_NAME}';
\$force_install_type = '${DOLI_DB_TYPE}';
\$force_install_dbserver = '${DOLI_DB_HOST}';
\$force_install_port = ${DOLI_DB_PORT};
\$force_install_prefix = '${DOLI_DB_PREFIX}';
\$force_install_createdatabase = false;
\$force_install_databaselogin = '${DOLI_DB_USER}';
\$force_install_databasepass = '${DOLI_DB_PASSWORD}';
\$force_install_createuser = false;
\$force_install_databaserootlogin = '${DOLI_DB_USER}';
\$force_install_databaserootpass = '${DOLI_DB_PASSWORD}';
\$force_install_dolibarrlogin = '${DOLI_ADMIN_LOGIN}';
\$force_install_lockinstall = true;
\$force_install_module = 'modSociete,modFournisseur,modFacture';
EOF

			# XXX Would it be possible to call official install from command line?

			echo "You shall complete Dolibarr install at '${DOLI_URL_ROOT}/install'"
		fi
	fi
fi

if [ -f /var/www/documents/install.lock ]; then
	echo $image_version > /var/www/documents/install.version
fi

exec "$@"
