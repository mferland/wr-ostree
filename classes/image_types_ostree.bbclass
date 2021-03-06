# OSTree deployment

do_image_ostree[depends] = "ostree-native:do_populate_sysroot \
                        openssl-native:do_populate_sysroot \
			coreutils-native:do_populate_sysroot \
                        virtual/kernel:do_deploy \
                        ${OSTREE_INITRAMFS_IMAGE}:do_image_complete"

#export REPRODUCIBLE_TIMESTAMP_ROOTFS ??= "`date --date="20${WRLINUX_YEAR_VERSION}-01-01 +${WRLINUX_WW_VERSION}weeks" +%s`"
export BUILD_REPRODUCIBLE_BINARIES = "1"

export OSTREE_REPO
export OSTREE_BRANCHNAME
OSTREE_KERNEL ??= "${KERNEL_IMAGETYPE}"

RAMDISK_EXT ?= ".${INITRAMFS_FSTYPES}"

export SYSTEMD_USED = "${@oe.utils.ifelse(d.getVar('VIRTUAL-RUNTIME_init_manager', True) == 'systemd', 'true', '')}"
export GRUB_USED = "${@oe.utils.ifelse(d.getVar('OSTREE_BOOTLOADER', True) == 'grub', 'true', '')}"
export FLUXDATA = "${@bb.utils.contains('DISTRO_FEATURES', 'luks', 'luks_fluxdata', 'fluxdata', d)}"

repo_apache_config () {
    local _repo_path
    local _repo_alias

    cd $OSTREE_REPO && _repo_path=$(pwd) && cd -
    _repo_alias="/${OSTREE_OSNAME}/${MACHINE}/"

    echo "* Generating apache2 config fragment for $OSTREE_REPO..."
    (echo "Alias \"$_repo_alias\" \"$_repo_path/\""
     echo ""
     echo "<Directory $_repo_path>"
     echo "    Options Indexes FollowSymLinks"
     echo "    Require all granted"
     echo "</Directory>") > ${DEPLOY_DIR_IMAGE}/${IMAGE_LINK_NAME}.rootfs.ostree.http.conf
}

python check_rpm_public_key () {
    gpg_path = d.getVar('GPG_PATH', True)

    gpg_bin = d.getVar('GPG_BIN', True) or \
              bb.utils.which(os.getenv('PATH'), 'gpg')
    d.setVar('OSTREE_GPG_BIN', gpg_bin)
    gpg_keyid = d.getVar('OSTREE_GPGID', True)

    # Check RPM_GPG_NAME and RPM_GPG_PASSPHRASE
    cmd = "%s --homedir %s --list-keys \"%s\"" % \
            (gpg_bin, gpg_path, gpg_keyid)
    status, output = oe.utils.getstatusoutput(cmd)
    if not status:
        return

    # Import RPM_GPG_NAME if not found
    gpg_key = d.getVar('OSTREE_GPGDIR', True) + '/' + 'RPM-GPG-PRIVKEY-' + gpg_keyid
    cmd = '%s --batch --homedir %s --passphrase %s --import "%s"' % \
            (gpg_bin, gpg_path, d.getVar('OSTREE_GPG_PASSPHRASE', True), gpg_key)
    status, output = oe.utils.getstatusoutput(cmd)
    if status:
        d.setVar('GPG_PATH', '')
        d.setVar('OSTREE_GPGID', '')
        return
}
check_rpm_public_key[lockfiles] = "${TMPDIR}/check_rpm_public_key.lock"

python () {
    gpg_path = d.getVar('GPG_PATH', True)
    if not gpg_path:
        gpg_path = d.getVar('TMPDIR', True) + '/.gnupg'
        d.setVar('GPG_PATH', gpg_path)

    if not os.path.exists(gpg_path):
        status, output = oe.utils.getstatusoutput('mkdir -m 0700 -p %s' % gpg_path)
        if status:
            raise bb.build.FuncFailed('Failed to create gpg keying %s: %s' %
                                      (gpg_path, output))

    is_image = bb.data.inherits_class('image', d)
    if is_image:
        bb.build.exec_func("check_rpm_public_key", d)
}

create_tarball_and_ostreecommit[vardepsexclude] = "DATETIME"
create_tarball_and_ostreecommit() {
	local _image_basename=$1
	local _timestamp=$2

	# The timestamp format of ostree requires
	_timestamp=`LC_ALL=C date --date=@$_timestamp`

	# Create a tarball that can be then commited to OSTree repo
	OSTREE_TAR=${DEPLOY_DIR_IMAGE}/${_image_basename}-${MACHINE}-${DATETIME}.rootfs.ostree.tar.bz2
	tar -C ${OSTREE_ROOTFS} --xattrs --xattrs-include='*' -cjf ${OSTREE_TAR} .
	sync

	ln -snf ${_image_basename}-${MACHINE}-${DATETIME}.rootfs.ostree.tar.bz2 \
	    ${DEPLOY_DIR_IMAGE}/${_image_basename}-${MACHINE}.rootfs.ostree.tar.bz2

	# Commit the result
	if [ -z "${OSTREE_GPGID}" ]; then
		bbwarn "Ostree repo created without gpg.\n" \
		       "This usually indicates a failure to find /usr/bin/gpg,"
		       "or you tried to use an invalid GPG database.  "
		       "It could also be possible that OSTREE_GPGID, OSTREE_GPG_PASSPHRASE, "
		       "WR_KEYS_DIR has a bad value."
		ostree --repo=${OSTREE_REPO} commit \
			--tree=dir=${OSTREE_ROOTFS} \
			--skip-if-unchanged \
			--branch=${_image_basename} \
			--timestamp=${_timestamp} \
			--subject="Commit-id: ${_image_basename}-${MACHINE}-${DATETIME}"
	else
		# Setup gpg key for signing
		if [ -n "${OSTREE_GPGID}" ] && [ -n "${OSTREE_GPG_PASSPHRASE}" ] && [ -n "${GPG_PATH}" ] ; then
			gpg_ver=`${OSTREE_GPG_BIN} --version | head -1 | awk '{ print $3 }' | awk -F. '{ print $1 }'`
			echo '#!/bin/bash' > ${WORKDIR}/gpg
			if [ "$gpg_ver" = "1" ] ; then
				# GPGME has to be tricked into running a helper script to provide a passphrase when using gpg 1
				echo 'exarg=""' >> ${WORKDIR}/gpg
				echo 'echo "$@" |grep -q batch && exarg="--passphrase ${OSTREE_GPG_PASSPHRASE}"' >> ${WORKDIR}/gpg
			elif [ "$gpg_ver" = "2" ] ; then
				gpg_connect=$(dirname $(which ${OSTREE_GPG_BIN}))/gpg-connect-agent
				if [ ! -f $gpg_connect ] ; then
					bb.fatal "ERROR Could not locate gpg-connect-agent at: $gpg_connect"
				fi
				if [ -f "${GPG_PATH}/gpg-agent.conf" ] ; then
					if ! grep -q allow-loopback-pin "${GPG_PATH}/gpg-agent.conf" ; then
						echo allow-loopback-pinentry >> "${GPG_PATH}/gpg-agent.conf"
						$gpg_connect --homedir ${GPG_PATH} reloadagent /bye
					fi
				else
					echo allow-loopback-pinentry > "${GPG_PATH}/gpg-agent.conf"
					$gpg_connect --homedir ${GPG_PATH} reloadagent /bye
				fi
				${OSTREE_GPG_BIN} --homedir=${GPG_PATH} -o /dev/null -u "${OSTREE_GPGID}" --pinentry=loopback --passphrase ${OSTREE_GPG_PASSPHRASE} -s /dev/null
			fi
			echo 'exec ${OSTREE_GPG_BIN} $exarg $@' >> ${WORKDIR}/gpg
			chmod 700 ${WORKDIR}/gpg
		fi
		PATH="${WORKDIR}:$PATH" ostree --repo=${OSTREE_REPO} commit \
			--tree=dir=${OSTREE_ROOTFS} \
			--skip-if-unchanged \
			--gpg-sign="${OSTREE_GPGID}" \
			--gpg-homedir=${GPG_PATH} \
			--branch=${_image_basename} \
			--timestamp=${_timestamp} \
			--subject="Commit-id: ${_image_basename}-${MACHINE}-${DATETIME}"
		rm -f ${WORKDIR}/gpg
        fi
}

IMAGE_CMD_ostree () {
	if [ -z "$OSTREE_REPO" ]; then
		bbfatal "OSTREE_REPO should be set in your local.conf"
	fi

	if [ -z "$OSTREE_BRANCHNAME" ]; then
		bbfatal "OSTREE_BRANCHNAME should be set in your local.conf"
	fi

	OSTREE_ROOTFS=`mktemp -du ${WORKDIR}/ostree-root-XXXXX`
	cp -a ${IMAGE_ROOTFS} ${OSTREE_ROOTFS}
	chmod a+rx ${OSTREE_ROOTFS}
	sync

	cd ${OSTREE_ROOTFS}

	# Create sysroot directory to which physical sysroot will be mounted
	mkdir sysroot
	ln -sf sysroot/ostree ostree

	rm -rf tmp/*
	ln -sf sysroot/tmp tmp

	mkdir -p usr/rootdirs

	mv etc usr/
	# Implement UsrMove
	dirs="bin sbin lib lib64"

	for dir in ${dirs} ; do
		if [ -d ${dir} ] && [ ! -L ${dir} ] ; then 
			mv ${dir} usr/rootdirs/
			rm -rf ${dir}
			ln -sf usr/rootdirs/${dir} ${dir}
		fi
	done
	
	if [ -n "$SYSTEMD_USED" ]; then
		mkdir -p usr/etc/tmpfiles.d
		tmpfiles_conf=usr/etc/tmpfiles.d/00ostree-tmpfiles.conf
		echo "d /var/rootdirs 0755 root root -" >>${tmpfiles_conf}
		# disable the annoying logs on the console
		echo "w /proc/sys/kernel/printk - - - - 3" >> ${tmpfiles_conf}
	else
		mkdir -p usr/etc/init.d
		tmpfiles_conf=usr/etc/init.d/tmpfiles.sh
		echo '#!/bin/sh' > ${tmpfiles_conf}
		echo "mkdir -p /var/rootdirs; chmod 755 /var/rootdirs" >> ${tmpfiles_conf}

		ln -s ../init.d/tmpfiles.sh usr/etc/rcS.d/S20tmpfiles.sh
	fi

	# Preserve data in /home to be later copied to /sysroot/home by
	#   sysroot generating procedure
	mkdir -p usr/homedirs
	if [ -d "home" ] && [ ! -L "home" ]; then
		mv home usr/homedirs/home
		mkdir var/home
		ln -sf var/home home
	fi

	echo "d /var/rootdirs/opt 0755 root root -" >>${tmpfiles_conf}
	if [ -d opt ]; then
		mkdir -p usr/rootdirs/opt
		for dir in `ls opt`; do
			mv opt/$dir usr/rootdirs/opt/
			echo "L /opt/$dir - - - - /usr/rootdirs/opt/$dir" >>${tmpfiles_conf}
		done
	fi
	rm -rf opt
	ln -sf var/rootdirs/opt opt

	if [ -d var/lib/rpm ]; then
	    mkdir -p usr/rootdirs/var/lib/
	    mv var/lib/rpm usr/rootdirs/var/lib/
	    echo "L /var/lib/rpm - - - - /usr/rootdirs/var/lib/rpm" >>${tmpfiles_conf}
	fi
	if [ -d var/lib/dnf ]; then
	    mkdir -p usr/rootdirs/var/lib/
	    mv var/lib/dnf usr/rootdirs/var/lib/
	    echo "L /var/lib/dnf - - - - /usr/rootdirs/var/lib/dnf " >>${tmpfiles_conf}
	fi

	# Move persistent directories to /var
	dirs="mnt media srv"

	for dir in ${dirs}; do
		if [ -d ${dir} ] && [ ! -L ${dir} ]; then
			if [ "$(ls -A $dir)" ]; then
				bbwarn "Data in /$dir directory is not preserved by OSTree. Consider moving it under /usr"
			fi

			if [ -n "$SYSTEMD_USED" ]; then
				echo "d /var/rootdirs/${dir} 0755 root root -" >>${tmpfiles_conf}
			else
				echo "mkdir -p /var/rootdirs/${dir}; chown 755 /var/rootdirs/${dir}" >>${tmpfiles_conf}
			fi
			rm -rf ${dir}
			ln -sf var/rootdirs/${dir} ${dir}
		fi
	done

	if [ -d root ] && [ ! -L root ]; then
        	if [ "$(ls -A root)" ]; then
                	bberror "Data in /root directory is not preserved by OSTree."
		fi

		if [ -n "$SYSTEMD_USED" ]; then
                       echo "d /var/rootdirs/root 0755 root root -" >>${tmpfiles_conf}
		else
                       echo "mkdir -p /var/rootdirs/root; chown 755 /var/rootdirs/root" >>${tmpfiles_conf}
		fi

		rm -rf root
		ln -sf var/rootdirs/root root
	fi

	# deploy SOTA credentials
	if [ -n "${SOTA_AUTOPROVISION_CREDENTIALS}" ]; then
		EXPDATE=`openssl pkcs12 -in ${SOTA_AUTOPROVISION_CREDENTIALS} -password "pass:" -nodes 2>/dev/null | openssl x509 -noout -enddate | cut -f2 -d "="`

		if [ `date +%s` -ge `date -d "${EXPDATE}" +%s` ]; then
			bberror "Certificate ${SOTA_AUTOPROVISION_CREDENTIALS} has expired on ${EXPDATE}"
		fi

		mkdir -p var/sota
		cp ${SOTA_AUTOPROVISION_CREDENTIALS} var/sota/sota_provisioning_credentials.p12
		if [ -n "${SOTA_AUTOPROVISION_URL_FILE}" ]; then
			export SOTA_AUTOPROVISION_URL=`cat ${SOTA_AUTOPROVISION_URL_FILE}`
		fi
		echo "SOTA_GATEWAY_URI=${SOTA_AUTOPROVISION_URL}" > var/sota/sota_provisioning_url.env
	fi


	# Creating boot directories is required for "ostree admin deploy"

	mkdir -p boot/loader.0
	mkdir -p boot/loader.1
	ln -sf boot/loader.0 boot/loader
	
	checksum=`sha256sum ${DEPLOY_DIR_IMAGE}/${OSTREE_KERNEL} | cut -f 1 -d " "`

#	cp ${DEPLOY_DIR_IMAGE}/${OSTREE_KERNEL} boot/vmlinuz-${checksum}
#	cp ${DEPLOY_DIR_IMAGE}/${OSTREE_INITRAMFS_IMAGE}-${MACHINE}${RAMDISK_EXT} boot/initramfs-${checksum}

        #deploy the device tree file 
        mkdir -p usr/lib/ostree-boot
        cp ${DEPLOY_DIR_IMAGE}/${OSTREE_KERNEL} usr/lib/ostree-boot/vmlinuz-${checksum}
        cp ${DEPLOY_DIR_IMAGE}/${OSTREE_INITRAMFS_IMAGE}-${MACHINE}${RAMDISK_EXT} usr/lib/ostree-boot/initramfs-${checksum}
	if [ -n "${@bb.utils.contains('DISTRO_FEATURES', 'efi-secure-boot', 'Y', '', d)}" ]; then
		cp ${DEPLOY_DIR_IMAGE}/${OSTREE_KERNEL}.p7b usr/lib/ostree-boot/vmlinuz.p7b
		cp ${DEPLOY_DIR_IMAGE}/${OSTREE_INITRAMFS_IMAGE}-${MACHINE}${RAMDISK_EXT}.p7b usr/lib/ostree-boot/initramfs.p7b
	fi
#	cp ${DEPLOY_DIR_IMAGE}/${OSTREE_KERNEL}.p7b usr/lib/ostree-boot/vmlinuz.p7b
#	cp ${DEPLOY_DIR_IMAGE}/${OSTREE_INITRAMFS_IMAGE}-${MACHINE}${RAMDISK_EXT}.p7b usr/lib/ostree-boot/initramfs.p7b
        if [ -d boot/efi ]; then
	   	cp -a boot/efi usr/lib/ostree-boot/
	fi

        if [ -f ${DEPLOY_DIR_IMAGE}/uEnv.txt ]; then
		cp ${DEPLOY_DIR_IMAGE}/uEnv.txt usr/lib/ostree-boot/
        fi

        if [ -f ${DEPLOY_DIR_IMAGE}/boot.scr ]; then
		cp ${DEPLOY_DIR_IMAGE}/boot.scr usr/lib/ostree-boot/boot.scr
        fi

        for i in ${KERNEL_DEVICETREE}; do
		if [ -f ${DEPLOY_DIR_IMAGE}/$(basename $i) ]; then
			cp ${DEPLOY_DIR_IMAGE}/$(basename $i) usr/lib/ostree-boot/
		fi
        done 

	#deploy the GPG pub key
	if [ -n "${OSTREE_GPGID}" ]; then
		if [ -f ${GPG_PATH}/pubring.gpg ]; then
			cp ${GPG_PATH}/pubring.gpg usr/share/ostree/trusted.gpg.d/pubring.gpg
		fi
		if [ -f ${GPG_PATH}/pubring.kbx ]; then
			cp ${GPG_PATH}/pubring.kbx usr/share/ostree/trusted.gpg.d/pubkbx.gpg
		fi
	fi

#        cp ${DEPLOY_DIR_IMAGE}/${MACHINE}.dtb usr/lib/ostree-boot
        touch usr/lib/ostree-boot/.ostree-bootcsumdir-source

	# Copy image manifest
	cat ${IMAGE_MANIFEST} | cut -d " " -f1,3 > usr/package.manifest

	# add the required mount
	echo "LABEL=otaboot     /boot    auto   defaults 0 0" >>usr/etc/fstab
        if [ -n "${GRUB_USED}" ]; then
	    echo "LABEL=otaefi     /boot/efi    auto   ro 0 0" >>usr/etc/fstab
        fi
	echo "LABEL=fluxdata	 /var    auto   defaults 0 0" >>usr/etc/fstab

	cd ${WORKDIR}

	if [ ! -d ${OSTREE_REPO} ]; then
		ostree --repo=${OSTREE_REPO} init --mode=archive-z2
	fi

	# Preserve OSTREE_BRANCHNAME for future information
	mkdir -p ${OSTREE_ROOTFS}/usr/share/sota/
	echo -n "${OSTREE_BRANCHNAME}-dev" > ${OSTREE_ROOTFS}/usr/share/sota/branchname
	timestamp=`date +%s`
	create_tarball_and_ostreecommit "${OSTREE_BRANCHNAME}-dev" "$timestamp"

	if [ "${OSTREE_NORPMDATA}" = 1 ] || [ ! -e ${OSTREE_ROOTFS}/usr/bin/rpm ] ; then
		# Clean up package management data for factory deploy
		rm -rf ${OSTREE_ROOTFS}/usr/rootdirs/var/lib/rpm/*
		rm -rf ${OSTREE_ROOTFS}/usr/rootdirs/var/lib/dnf/*
	fi

	# Make factory older than development which is helpful for ostree admin upgrade
	timestamp=`expr $timestamp - 1`
	echo -n "${OSTREE_BRANCHNAME}" > ${OSTREE_ROOTFS}/usr/share/sota/branchname
	create_tarball_and_ostreecommit "${OSTREE_BRANCHNAME}" "$timestamp"

	ostree summary -u --repo=${OSTREE_REPO} 
	repo_apache_config

	rm -rf ${OSTREE_ROOTFS}
}

IMAGE_TYPEDEP_ostreepush = "ostree"
do_image_ostreepush[depends] = "sota-tools-native:do_populate_sysroot"

IMAGE_CMD_ostreepush () {
	if [ -n "${OSTREE_PUSH_CREDENTIALS}" ]; then
		garage-push --repo=${OSTREE_REPO} \
			    --ref=${OSTREE_BRANCHNAME} \
			    --credentials=${OSTREE_PUSH_CREDENTIALS} \
			    --cacert=${STAGING_ETCDIR_NATIVE}/ssl/certs/ca-certificates.crt

		garage-push --repo=${OSTREE_REPO} \
			    --ref=${OSTREE_BRANCHNAME}-dev \
			    --credentials=${OSTREE_PUSH_CREDENTIALS} \
			    --cacert=${STAGING_ETCDIR_NATIVE}/ssl/certs/ca-certificates.crt

	fi
}
