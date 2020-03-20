#!/usr/bin/env bash

# Script that supports the installation, setup and upgrade of fireguai through the use of Docker containers

DOCKER_COMPOSE="docker-compose -p fireguai"
DOCKER_PREFIX="fireguai/docker:"

DOCKER="docker"
CURL="curl"
PROGNAME="$0"
VOLUMES="certificates letsencrypt certbot database privatekey publickey"
CONTAINERS="web app db log certbot"

TMPDIR=`mktemp -d`

# Help: print out help on running the script
  function fireguaiHelp() {
		echo "Usage: ${PROGNAME} <install|upgrade|start|stop|reset|renew-ssl|backup|restore>"
	}

# Install = Download + Setup
  function fireguaiInstall() {
		_fireguaiDownload && _fireguaiSetup
	}

# Download: download latest version of published docker containers from docker public repository

	function _fireguaiDownload() {
		echo "[*] Downloading latest version of fireguai."
		_fireguaiCleanup

		${CURL} -Lso docker-compose.yml "https://flow.gi/fireguai-web/docker-compose-run.yml"

		if [ "$?" -ne 0 ]; then
		  echo "[-] ERROR: Unable to download fireguai: cannot get docker compose file"
			_fireguaiCleanup
			exit 1
		else
		  export LISTENIP="127.0.0.1"
			${DOCKER_COMPOSE} pull

			if [ "$?" -ne 0 ]; then
				echo "[-] ERROR: Unable to download fireguai: cannot obtain docker images"
				_fireguaiCleanup
				exit 1
			fi
		fi
	}

# Setup: conduct the initial setup of a just downloaded clean set of images

	function _fireguaiSetup() {
		echo "[*] Running initial setup of fireguai."

		# Check that the images have not been previously set-up
    ${DOCKER} run --rm -v "fireguai_privatekey:/home/user/.ssh/" -it ${DOCKER_PREFIX}fireguai_setup fireguai-setup dirty-check

		if [ "$?" -ne 0 ]; then
		  echo "[-] ERROR: Unable to initialise fireguai: fireguai is already initialised, continuing setup will destroy all current data. If you really want to proceed please run '${PROGNAME} reset' before trying to reinstall"
		else

			_fireguaiCreatePersist

			export FIREGUAI_DEVISE_JWT_SECRET_KEY="tempvalue"
			export FIREGUAI_SECRET_KEY_BASE="tempvalue"

			fireguaiStart "SETUP" "Starting fireguai in setup mode"

			if [ "$?" -ne 0 ]; then
			  echo "[-] ERROR: Unable to initialise fireguai: error starting up fireguai images."
			else

        _fireguaiSSHSetup

				if [ "$?" -ne 0 ]; then
					echo "[-] ERROR: Unable to initialise fireguai: error during SSH setup."
				else
					# SSL certificate set-up with local certificate or LetsEncrypt

					# Check if we have local certificate and key files

					if [ -f "fireguai.cer" ] && [ -f "fireguai.key" ]; then
						# We have local files, copy them over
						echo "[+] Found local certificate and key, installing them"
						${DOCKER} container rm fireguai_setup 2> /dev/null
						${DOCKER} run --name "fireguai_setup" -v "fireguai_certificates:/opt/ssl" -it ${DOCKER_PREFIX}fireguai_setup 'rm /opt/ssl/fireguai.cer && /opt/ssl/fireguai.key'  > /dev/null
						${DOCKER} cp fireguai.cer fireguai_setup:/opt/ssl
						${DOCKER} cp fireguai.key fireguai_setup:/opt/ssl
						${DOCKER} container rm fireguai_setup
					fi

		  	  ${DOCKER} run --rm -v "fireguai_certificates:/opt/ssl" -v "fireguai_privatekey:/home/user/.ssh" --network fireguai_frontend -it ${DOCKER_PREFIX}fireguai_setup fireguai-setup ssl-setup

					if [ "$?" -ne 0 ]; then
						echo "[-] ERROR: Unable to initialise fireguai: error during SSL setup."
					else
						# Application setup before migration
						FIREGUAI_ENV=`${DOCKER} run --rm -v "fireguai_certificates:/opt/ssl" -v "fireguai_privatekey:/home/user/.ssh" --network fireguai_frontend -it ${DOCKER_PREFIX}fireguai_setup fireguai-setup app-init`

						if [ "$?" -ne 0 ] && [ "${FIREGUAI_ENV}" == "" ]; then
							echo "[-] ERROR: Unable to initialise fireguai: error during application setup."
							unset FIREGUAI_ENV
						else
						  # Create fireguai env with secret keys and other parameters
							echo "${FIREGUAI_ENV}" > .env

							# Database setup and initial migration
							${DOCKER} run --rm -v "fireguai_certificates:/opt/ssl" -v "fireguai_privatekey:/home/user/.ssh" --network fireguai_backend -it ${DOCKER_PREFIX}fireguai_setup fireguai-setup db-migrate

							if [ "$?" -ne 0 ]; then
								echo "[-] ERROR: Unable to initialise fireguai: error during database setup."
							else
								# Create initial administrator user and show password
								DEFAULT_EMAIL="admin@example.com"
								read -p "[*] fireguai will now create an initial administrative account, what is your e-mail address (default: ${DEFAULT_EMAIL})? "

								REPLY=`echo ${REPLY} | tr -d '\r\n'`

								if [ ! -z "${REPLY}"  ]; then
									DEFAULT_EMAIL=${REPLY}
								fi

								FIREGUAI_PASSWORD=`${DOCKER} run --rm -v "fireguai_certificates:/opt/ssl" -v "fireguai_privatekey:/home/user/.ssh" --network fireguai_backend -it ${DOCKER_PREFIX}fireguai_setup fireguai-setup app-create_default_user ${DEFAULT_EMAIL}`

								if [ "$?" -ne 0 ]; then
									echo "[-] ERROR: Unable to initialise fireguai: error creating administrator user."
									unset FIREGUAI_PASSWORD
								else
							    ${DOCKER} run --rm -v "fireguai_privatekey:/home/user/.ssh/" -it ${DOCKER_PREFIX}fireguai_setup fireguai-setup dirty-mark
								fi
							fi
						fi
					fi
				fi

				fireguaiStop "Completing fireguai setup mode."

				if [ "${FIREGUAI_PASSWORD}" != "" ]; then
							FIREGUAI_USERNAME=`echo ${FIREGUAI_PASSWORD}| cut -d\: -f 1`
							FIREGUAI_PASSWORD=`echo ${FIREGUAI_PASSWORD}| cut -d\: -f 2`
				      echo "[!] Created initial administrator username '${FIREGUAI_USERNAME}' and password: ${FIREGUAI_PASSWORD}"
							echo "[+] Successfully installed fireguai, use '${PROGNAME} start' to run it now"
				else
					_fireguaiSetupCleanup
					exit 1
				fi
			fi
		fi

		exit

	}

	# Clean-up a botched installation
  function _fireguaiSetupCleanup() {
		echo "[*] Cleaning up installation"
		_fireguaiContainerDelete
		_fireguaiVolumeDelete
		_fireguaiCleanup
	}

# Clean-up a botched installation
  function _fireguaiCleanup() {
		rm -f docker-compose.yml
	}

# Create persist structure
  function _fireguaiCreatePersist() {
		_fireguaiVolumeDelete

		echo "[*] Creating data containers"
		_fireguaiVolumeCreate
	}

	# Create empty containers
	function _fireguaiVolumeCreate() {
		for VOLUME in ${VOLUMES}; do
			${DOCKER} volume create fireguai_${VOLUME}
		done
	}

	# Delete volumes
	function _fireguaiVolumeDelete() {
		for VOLUME in ${VOLUMES}; do
			${DOCKER} volume rm fireguai_${VOLUME} 2>/dev/null
		done
	}

	# Delete containers
	function _fireguaiContainerDelete() {
		for CONTAINER in ${CONTAINERS}; do
			${DOCKER} container rm fireguai_${CONTAINER} 2>/dev/null
		done
	}

# Start: bring up the docker instances

	function fireguaiStart() {
		ENVIRONMENT="$1"
		MESSAGE="$2"

		if [ ${ENVIRONMENT} == "SETUP" ]; then
		  export LISTENIP="127.0.0.1"
		fi

		if [ -z "${MESSAGE}" ]; then
		  MESSAGE="Starting fireguai"
		fi

		echo "[*] $MESSAGE ($ENVIRONMENT)."
		${DOCKER_COMPOSE} up -d web app db setup
	}

	# Stop: bring down the docker instances
	function fireguaiStop() {
		MESSAGE="$1"

		if [ -z "${MESSAGE}" ]; then
		  MESSAGE="Stopping fireguai."
		fi

		echo "[*] $MESSAGE"
		${DOCKER_COMPOSE} down
	}

	# Upgrade
	function fireguaiUpgrade() {
		echo "[*] Upgrading fireguai to the latest version"
		echo "TODO"
		echo "Take a backup as fireguai-upgrade-backup-<version>.tgz"
	}

	# Reset
	function fireguaiReset() {
		REPLY="no"

		# Check if dirty
    ${DOCKER} run --rm -v "fireguai_privatekey:/home/user/.ssh/" -it ${DOCKER_PREFIX}fireguai_setup fireguai-setup dirty-check
	
		if [ "$?" -ne 0 ]; then
			# Show banner and ask for confirmation
		  read -n 1 -p "[!] fireguai is installed and in use in your system, continuing will destroy all data. Are you sure you want to continue? (y/n) "
			REPLY=`echo ${REPLY} | tr 'YES' 'yes'`
			echo ""
		else
			REPLY="yes"
		fi

		if [ "${REPLY}" == "y" -o "${REPLY}" == "yes" ]; then
			# Stop fireguai
			fireguaiStop

			# Delete containers and volumes
			_fireguaiContainerDelete
			_fireguaiContainerDelete
			_fireguaiVolumeDelete
			echo "[+] fireguai reset, all data has been deleted"
		else
			echo "[-] Reset cancelled, not making any changes"
		fi
	}

	# Install a renewed SSL certificate
	function fireguaiSSLRenew() {

		# Check that the fireguai instance is already setup
    ${DOCKER} run --rm -v "fireguai_privatekey:/home/user/.ssh/" -it ${DOCKER_PREFIX}fireguai_setup fireguai-setup dirty-check
	
		if [ "$?" -ne 0 ]; then

			if [ -f "fireguai.cer" ] && [ -f "fireguai.key" ]; then

				SSL_CN=`openssl x509 -in fireguai.cer -noout -subject | cut -f 2- -d\=`

				if [ "$?" -ne 0 ]; then
					echo "[-] ERROR: The provided fireguai.cer file does not look like a certificate, please review the certificate and private key are correct and try again."
					exit -1
				fi

				echo "[+] Renewed SSL certificate found, installing them on the existing fireguai instance (subject: \"${SSL_CN}\")"

				${DOCKER} cp fireguai.cer fireguai_setup:/opt/ssl
				${DOCKER} cp fireguai.key fireguai_setup:/opt/ssl
			else
				echo "[-] ERROR: Unable to find renewed SSL certificate (fireguai.cer) or private key (fireguai.key) files in the current directory"
			fi
		else
			echo "[-] ERROR: Unable to find a fireguai instance to install renewed certificates to, are you sure you have already installed it?"
		fi
	}

	# Backup data volumes

	function fireguaiBackup() {

		MOUNT=""

		for VOLUME in ${VOLUMES}; do
		  MOUNT="${MOUNT} -v fireguai_${VOLUME}:/backup/fireguai_${VOLUME}"
		done

		${DOCKER} container rm fireguai_setup_backup 2>/dev/null
	  ${DOCKER} run --name "fireguai_setup_backup" -v $(pwd):/backup_output ${MOUNT} -it ${DOCKER_PREFIX}fireguai_setup fireguai-setup backup
		${DOCKER} container rm fireguai_setup_backup

	}

	# Restore data volumes from a backup

	function fireguaiRestore() {
		echo "TBC: Restoring of container volumes"
	}

	# Check pre-requisites

	function _fireguaiPrerequisites() {

		if ! [ -x "$(command -v ${DOCKER})" ]; then
      echo "[-] docker is required, but was not found"
      exit 1
    fi

		if ! [ -x "$(command -v ${DOCKER_COMPOSE})" ]; then
      echo "[-] docker-compose is required, but was not found"
      exit 1
    fi

		if ! [ -x "$(command -v ${CURL})" ]; then
      echo "[-] curl is required, but was not found"
      exit 1
    fi

		echo "[+] Pre-requisite \"docker\" found, version: $(${DOCKER} -v)"
		echo "[+] Pre-requisite \"docker-compose\" found, version: $(${DOCKER_COMPOSE} -v)"

	}

	# Generate an SSH key to run remote commands from the setup instance on the other containers and install it
	function _fireguaiSSHSetup() {
			echo "[*] Generating and distributing SSH keys"

		# Generate a password-less key
		${DOCKER} container rm fireguai_setup_ssh 2>/dev/null
	  ${DOCKER} run --name "fireguai_setup_ssh" -v "fireguai_privatekey:/home/user/.ssh" -it ${DOCKER_PREFIX}fireguai_setup fireguai-setup ssh-setup
		${DOCKER} cp fireguai_setup_ssh:/home/user/.ssh/id_rsa.pub ${TMPDIR}
		${DOCKER} container rm fireguai_setup_ssh

		# Distribute key

		${DOCKER} cp ${TMPDIR}/id_rsa.pub fireguai_certbot:/home/certbot/.ssh/authorized_keys
		${DOCKER} cp ${TMPDIR}/id_rsa.pub fireguai_web:/var/www/.ssh/authorized_keys
		${DOCKER} cp ${TMPDIR}/id_rsa.pub fireguai_app:/home/user/.ssh/authorized_keys

	}	

############################# Main script ##################################

_fireguaiPrerequisites

case "$1" in

	'install')
		shift

		while [[ $# -gt 0 ]]
		do
		key="$1"

		case $key in
				-d|--devel|--development)
					shift # past argument
					export DOCKER_PREFIX=""
					echo "[!] Running in DEVELOPMENT mode"
					;;
				*)    # unknown option
					echo "[-] Invalid argument '$1'"
					exit 1
				;;
		esac
		done


		fireguaiInstall
		;;

	'upgrade')
		fireguaiUpgrade
		;;

	'start')
		shift
		export LISTENIP="0.0.0.0"

		while [[ $# -gt 0 ]]
		do
		key="$1"

		case $key in
				-l|--listen-ip)
					export LISTENIP="$2"
					shift # past argument
					shift # past value
					echo "[*] Listening on $LISTENIP"
					;;

				-d|--devel|--development)
					shift # past argument
					export DOCKER_PREFIX=""
					echo "[!] Running in DEVELOPMENT mode"
					;;

				*)    # unknown option
					echo "[-] Invalid argument '$1'"
					exit 1
				;;
		esac
		done

		fireguaiStart "PRODUCTION"
		;;

	'stop')
		fireguaiStop
		;;

	'reset')
		fireguaiReset
		;;

	'renew-ssl')
		fireguaiSSLRenew
		;;

	'backup')
		shift

		while [[ $# -gt 0 ]]
		do
		key="$1"

		case $key in
				-d|--devel|--development)
					shift # past argument
					export DOCKER_PREFIX=""
					echo "[!] Running in DEVELOPMENT mode"
					;;

				*)    # unknown option
					echo "[-] Invalid argument '$1'"
					exit 1
				;;
		esac
		done

		fireguaiBackup
		;;

	'restore')
		fireguaiRestore
		;;

	*)
		fireguaiHelp
		;;

esac
