#!/bin/bash

[ -z "${log}" ] && log="install-roundcube.log"
[ -z "${errorprefix}" ] && errorprefix="${0}: "

if [ -d bup ]; then
  echo "${errorprefix}directory bup already exists!" 1>&2
  exit 1
else
  mkdir -p bup
fi

# mysql root password
[ -z "${mysqlrootpasswd}" ] && read -s -p "mysqlrootpasswd []:" mysqlrootpasswd
echo ''

if [ -z "${mysqlroundcubepasswd}" ]; then
  tmp=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 20 | head -n 1)
  read -p "mysqlroundcubepassword [${tmp}]:" mysqlroundcubepasswd
  mysqlroundcubepasswd="${mysqlroundcubepasswd:-${tmp}}"
  unset tmp
fi

# apache webserver root
if [ -z "${httproot}" ]; then
  tmp="/var/www"
  read -p "httproot [${tmp}]: " httproot
  httproot="${httproot:-${tmp}}"
  unset tmp
fi

# name for roundcube root and apache site
if [ -z "${roundcubesitename}" ]; then
  tmp="roundcube"
  read -p "roundcubesitename [${tmp}]: " roundcubesitename
  roundcubesitename="${roundcubesitename:-${tmp}}"
  unset tmp
fi

# displayed name on the website
if [ -z "${roundcubeproductname}" ]; then
  tmp="Roundcube Webmail"
  read -p "roundcubeproductname [${tmp}]: " roundcubeproductname
  roundcubeproductname="${roundcubeproductname:-${tmp}}"
  unset tmp
fi

# leave empty to autodetect from user agent
if [ -z "${roundcubelanguage}" ]; then
  tmp="en_US"
  read -p "roundcubelanguage [${tmp}]: " roundcubelanguage
  roundcubelanguage="${roundcubelanguage:-${tmp}}"
  unset tmp
fi

# linux username (required for cronjob)
if [ -z "${user}" ]; then
  tmp="root"
  read -p "user [${tmp}]: " user
  user="${user:-${tmp}}"
  unset tmp
fi

# domain name
if [ -z "${domain}" ]; then
  tmp="yourdomain.tld"
  read -p "domain [${tmp}]: " domain
  domain="${domain:-${tmp}}"
  unset tmp
fi
 
roundcuberoot="${httproot}/${roundcubesitename}"

wget https://github.com/roundcube/roundcubemail/releases/download/1.5.2/roundcubemail-1.5.2-complete.tar.gz -O /tmp/roundcubemail-1.1.0.tar.gz 2>> "${log}"
[ -e /tmp/roundcubemail-1.1.0.tar.gz ] || {
  echo "${errorprefix}/tmp/roundcubemail-1.1.0.tar.gz not found - exiting"
  exit 1
}
mkdir -p bup"${httproot}"
[ -d "${roundcuberoot}" ] && mv "${roundcuberoot}" bup"${httproot}"
tar -C "${httproot}" -zxpf /tmp/roundcubemail-*.tar.gz
rm -f /tmp/roundcubemail-*.tar.gz 
mv "${httproot}"/roundcubemail-* "${roundcuberoot}"
[ -d "${roundcuberoot}" ] || {
  echo "${errorprefix}${roundcuberoot} not found - exiting"
  exit 1
}
[ -e "${roundcuberoot}"/config/config.inc.php.sample ] || {
  echo "${errorprefix}${roundcuberoot}/config/config.inc.php.sample not found - exiting"
  exit 1
}
[ -d "${roundcuberoot}"/installer ] || {
  echo "${errorprefix}${roundcuberoot}/installer not found - exiting"
  exit 1
}

(cd "${roundcuberoot}" && curl -sS https://getcomposer.org/installer | php)
(cd "${roundcuberoot}" && mv composer.json-dist composer.json && php composer.phar install --no-dev)

chown -R "${user}":www-data "${roundcuberoot}"
chmod -R 775 "${roundcuberoot}"/temp
chmod -R 775 "${roundcuberoot}"/logs

mkdir -p bup/etc/apache2/sites-available
[ -e /etc/apache2/sites-available/"${roundcubesitename}" ] && cp -a /etc/apache2/sites-available/"${roundcubesitename}" bup/etc/apache2/sites-available/

sed -e "s/roundcubesitename/${roundcubesitename}/g;s/yourusername/${user}/g;s/yourdomain\.tld/${domain}/g" << 'EOF' > /etc/apache2/sites-available/"${roundcubesitename}"
<VirtualHost *:80>
	ServerAdmin yourusername@yourdomain.tld
	ServerName roundcubesitename.yourdomain.tld
EOF

sed -e "s/\/var\/www\/roundcube/$(echo ${roundcuberoot} | sed -e 's/\//\\\//g')/g" << 'EOF' >> /etc/apache2/sites-available/"${roundcubesitename}"
	DocumentRoot /var/www/roundcube

	<Directory /var/www/roundcube>
		Options +FollowSymLinks
		# AddDefaultCharset     UTF-8
		AddType text/x-component .htc

		<IfModule mod_php5.c>
			php_flag        display_errors  Off
			php_flag        log_errors      On
			# php_value     error_log       logs/errors
			php_value       upload_max_filesize     10M
			php_value       post_max_size           12M
			php_value       memory_limit            64M
			php_flag        zlib.output_compression         Off
			php_flag        magic_quotes_gpc                Off
			php_flag        magic_quotes_runtime            Off
			php_flag        zend.ze1_compatibility_mode     Off
			php_flag        suhosin.session.encrypt         Off
			#php_value      session.cookie_path             /
			php_flag        session.auto_start      Off
			php_value       session.gc_maxlifetime  21600
			php_value       session.gc_divisor      500
			php_value       session.gc_probability  1
		</IfModule>

		<IfModule mod_rewrite.c>
			RewriteEngine On
			RewriteRule ^favicon\.ico$ skins/larry/images/favicon.ico
			# security rules:
			# - deny access to files not containing a dot or starting with a dot
			#   in all locations except installer directory
			RewriteRule ^(?!installer)(\.?[^\.]+)$ - [F]
			# - deny access to some locations
			RewriteRule ^/?(\.git|\.tx|SQL|bin|config|logs|temp|tests|program\/(include|lib|localization|steps)) - [F]
			# - deny access to some documentation files
			RewriteRule /?(README\.md|composer\.json-dist|composer\.json|package\.xml)$ - [F]
		</IfModule>

		<IfModule mod_deflate.c>
			SetOutputFilter DEFLATE
		</IfModule>

		<IfModule mod_headers.c>
			# replace 'append' with 'merge' for Apache version 2.2.9 and later
			# Header append Cache-Control public env=!NO_CACHE
		</IfModule>

		<IfModule mod_expires.c>
			ExpiresActive On
			ExpiresDefault "access plus 1 month"
		</IfModule>

		FileETag MTime Size

		<IfModule mod_autoindex.c>
			Options -Indexes
		</ifModule>

		AllowOverride None
		Order allow,deny
		Allow from all
	</Directory>
	
	<Directory /var/www/roundcube/plugins/enigma/home>
		Options -FollowSymLinks
		AllowOverride None
		Order allow,deny
		Deny from all
	</Directory>

	<Directory /var/www/roundcube/config>
		Options -FollowSymLinks
		AllowOverride None
		Order allow,deny
		Deny from all
	</Directory>

	<Directory /var/www/roundcube/temp>
		Options -FollowSymLinks
		AllowOverride None
		Order allow,deny
		Deny from all
	</Directory>

	<Directory /var/www/roundcube/logs>
		Options -FollowSymLinks
		AllowOverride None
		Order allow,deny
		Deny from all
	</Directory>
	
EOF

sed -e "s/roundcubesitename/${roundcubesitename}/g" << 'EOF' >> /etc/apache2/sites-available/"${roundcubesitename}"
	ErrorLog /var/log/apache2/error_roundcubesitename.log

	# Possible values include: debug, info, notice, warn, error, crit,
	# alert, emerg.
	LogLevel warn

	CustomLog /var/log/apache2/access_roundcubesitename.log combined
	
</VirtualHost>
EOF

mkdir -p bup/sql
mysqldump -u root -p"${mysqlrootpasswd}" 'roundcube' > bup/sql/roundcube.sql 2>> "${log}"

mysql --user=root --password="${mysqlrootpasswd}" -e "CREATE DATABASE IF NOT EXISTS \`roundcube\`;"
mysql --user=root --password="${mysqlrootpasswd}" -e "GRANT ALL PRIVILEGES ON \`roundcube\`.* TO 'roundcube'@'localhost' IDENTIFIED BY '${mysqlroundcubepasswd}';"
mysql --user=root --password="${mysqlrootpasswd}" -e "FLUSH PRIVILEGES;"

mysql -u root -p"${mysqlrootpasswd}" 'roundcube' < "${roundcuberoot}"/SQL/mysql.initial.sql 2>> "${log}"

cp -a "${roundcuberoot}"/config/config.inc.php.sample "${roundcuberoot}"/config/config.inc.php

deskey=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9-_#&!*%?' | fold -w 24 | head -n 1)

sed -e "s/mysqlroundcubepasswd/$(echo ${mysqlroundcubepasswd} | sed -e 's/\&/\\\&/g')/;s/roundcubeproductname/${roundcubeproductname}/;s/deskey/$(echo ${deskey} | sed -e 's/\&/\\\&/g')/;s/roundcubelanguage/${roundcubelanguage}/" << 'EOF' > "${roundcuberoot}"/config/config.inc.php
<?php
$config['db_dsnw'] = 'mysql://roundcube:mysqlroundcubepasswd@localhost/roundcube';
$config['log_driver'] = 'syslog';
$config['default_host'] = 'ssl://localhost';
$config['default_port'] = 993;
$config['smtp_server'] = 'ssl://localhost';
$config['smtp_port'] = 465;
$config['smtp_user'] = '';
$config['smtp_pass'] = '';
$config['support_url'] = '';
$config['ip_check'] = true;
$config['des_key'] = 'deskey';
$config['product_name'] = 'roundcubeproductname';
$config['plugins'] = array('archive','zipdownload');
$config['language'] = 'roundcubelanguage';
$config['enable_spellcheck'] = false;
$config['mail_pagesize'] = 50;
$config['draft_autosave'] = 300;
$config['mime_param_folding'] = 0;
$config['mdn_requests'] = 2;
$config['skin'] = 'larry';
EOF

rm -rf "${roundcuberoot}"/installer

tmp="$(mktemp -t crontab.tmp.XXXXXXXXXX)"
crontab -u "${user}" -l | sed "/$(echo ${roundcuberoot} | sed -e 's/\//\\\//g')\/bin\/cleandb\.sh/d" > "${tmp}"
echo "18 11 * * * ${roundcuberoot}/bin/cleandb.sh > /dev/null" >> "${tmp}"
crontab -u "${user}" "${tmp}"
rm -f "${tmp}"
unset tmp

a2enmod deflate
a2enmod expires
a2enmod headers
a2ensite "${roundcubesitename}"
service apache2 restart

## uninstall
echo '' >> "${log}"
echo 'uninstall roundcube using:' >> "${log}"
echo '' >> "${log}"
echo "mysql --user=root --password=yourpasswd -e \"DROP DATABASE \\\`roundcube\\\`;\"" >> "${log}"
echo "mysql --user=root --password=yourpasswd -e \"DROP USER 'roundcube'@'localhost';\"" >> "${log}"
echo "a2dissite ${roundcubesitename}" >> "${log}"
echo 'a2dismod expires' >> "${log}"
echo 'a2dismod headers' >> "${log}"
echo 'service apache2 restart' >> "${log}"
echo "rm /etc/apache2/sites-available/${roundcubesitename}" >> "${log}"
echo '' >> "${log}"
echo "remove the installation directory (${roundcuberoot})" >> "${log}"

echo ''
echo "check ${log} for erros"