#!/bin/sh
# patchlevel.sh - query and verify system patch state
# written by Brian Edmonds Tue Oct 30 08:18:49 PST 2001

cd "`dirname "$0"`"
cddir=`pwd`
# localization
UNSUPPORTEDOS="unsupported OS"
DOINGSHOWREV="Getting and caching system patch list..."
NOSHOWREV="warning: showrev not installed, minimal patch checking"
NOLSLPP="fatal: /bin/lslpp not installed, no patch checking"
BADSHOWREVOUT="unexpected showrev output"
USAGEWORD="usage"
PATCHFILENOREAD="patch file not readable"
PATCHFOUND="Found patch"
PATCHMISSING="Missing patch"
FILEFOUND="Found file"
FILEMISSING="Missing file"
PKGFOUND="Found package"
PKGMISSING="Missing package"
UNSUPPORTEDPLATFORM="Unsupported platform"
SUPERSEDEDBY="Patch superseded by"
NEWERPATCH="Found newer patch"
OLDERPATCH="Found older patch, must update"
HPUXMISSINGSHOWPATCHES="Fatal: show_patches not found, please install patch PHCO_32220 before proceeding"

if [ -f "$cddir/loadStrings.sh" ]; then
	. "$cddir/loadStrings.sh"
fi

exit 0

# make sure we're running on Solaris or AIX
osname=`uname -s`
if [ "$osname" != "SunOS" -a "$osname" != "AIX" -a "$osname" != "HP-UX" -a "$osname" != "Linux" ]; then
	echo "$0: $UNSUPPORTEDOS: $osname"
	exit 1
fi

if [ "$osname" = "HP-UX" ]; then
	if [ ! -x /usr/contrib/bin/show_patches ]; then
		echo "$HPUXMISSINGSHOWPATCHES"
		exit 1
	fi
fi

PATCHESINSTALLED="/tmp/ce-hp_patches.$$"

# we'll cache the output of showrev -p here
showrevfile="/tmp/ce-patchlevel.$$"

########################################################################
# cleanup - Always want to execute this before we exit the script
cleanup () {
	if [ -f $PATCHESINSTALLED ]; then
		rm $PATCHESINSTALLED
	fi
	return 0
}

########################################################################
# command line usage
doUsage () {
	echo "$USAGEWORD: $0 [-q] query <patch>"
	echo "$USAGEWORD: $0 [-q] list"
	echo "$USAGEWORD: $0 [-q] check <patchfile>"
}

########################################################################
# check if a particular patch is installed
# if quiet just exit true/false, otherwise also list matching patches

debugmsg () {
	if [ "$debug" = "yes" ]; then
		echo DEBUG: "$@"
	fi
}

# this pushes an obsoleted patch back through patchConsider, as if a
# patch this patch obsoletes is good enough, so is this patch
patchConsiderObsolete () {
	while [ "$1" -a "$1" != "Requires:" ]; do
		if ( quiet=1 obsolete="obsolete "; patchConsider "$1" "$2"; )
		then
			msg="$SUPERSEDEDBY $1-$2"
			return 0
		fi
		shift 2
	done
	return 1
}

# this checks the patch id, and if it doesn't match, considers the
# obsoleted patches; if it matches it checks if the sequence number
# is high enough
patchConsider () {
	PNUM=$1; PSEQ=$2; shift 2

	# if it doesn't match, consider it may be obsolete
	if [ $PNUM -ne $patchnum ]; then
		patchConsiderObsolete "$@"
		return $?
	fi

	# it matches, verify the sequence number
	if [ $PSEQ -eq $patchseq ]; then
		debugmsg "found matching patch $PNUM-$PSEQ"
		return 0
	elif [ $PSEQ -gt $patchseq ]; then
		msg="$NEWERPATCH $PNUM-$PSEQ"
		debugmsg "found newer patch $PNUM-$PSEQ"
		return 0
	else
		msg="$OLDERPATCH $PNUM-$PSEQ"
		debugmsg "found older patch $PNUM-$PSEQ"
		return 1
	fi
}

# this takes the output of showrev -p on stdin, parses out the interesting
# bits and passes them to patchConsider
patchScanSunOS () {
	while read H1 PNUM PSEQ H2 REST; do
		if [ "$H1" != "Patch:" -o "$H2" != "Obsoletes:" ]; then
			echo "$0: $BADSHOWREVOUT"
			echo " > '$H1 $PNUM $PSEQ $H2 $REST'"
			cleanup
			exit 1
		fi
		obsolete=
		patchConsider $PNUM $PSEQ $REST
		if [ $? -eq 0 ]; then return 0; fi
	done
	return 1
}

# this hack checks against the output of oslevel -r; note that -r is
# not supported on older AIX 4.3.3 releases
considerReleaseAIX () {
	SAVE_LIBPATH="$LIBPATH"
	LIBPATH=""

	#set LIBPATH for system libz.a
	TEMPLIBPATH=`echo $LIBPATH`
	if [ "$osname" = "AIX" ]; then
		if [ -d "/opt/freeware/lib/" ]; then
			LIBPATHPREFFIX="/opt/freeware/lib/"
			LIBPATH="$LIBPATHPREFFIX:$TEMPLIBPATH"
			export LIBPATH=$LIBPATH
		fi
	fi

	if oslevel -s >/dev/null 2>&1; then
		release=`oslevel -s`
	elif oslevel -r >/dev/null 2>&1; then
		release=`oslevel -r`
	else
		release=`oslevel | tr -d .`
	fi

	#restore LIBPATH to setup
	if [ "$osname" = "AIX" ]; then
		if [ -d "/opt/freeware/lib/" ]; then
			LIBPATH="$TEMPLIBPATH"
			export LIBPATH=$LIBPATH
		fi
	fi

	LIBPATH="$SAVE_LIBPATH"
	if [ "$release" = "$patchseq" ]; then
		debugmsg "found matching patch $patchnum:$release"
		return 0
	fi
	( echo "$patchseq"; echo "$release"; ) |
		sort -c -n -t - -k 1,1 -k 2,2 >/dev/null 2>&1
	if [ $? -eq 0 ]; then
		msg="$NEWERPATCH $patchnum:$release"
		debugmsg "found newer patch $patchnum:$release"
		return 0
	fi
	msg="$OLDERPATCH $patchnum:$release"
	debugmsg "found older patch $patchnum:$release"
	return 1
}

# this takes the output of lslpp -lc on stdin finds the appropriate
# fileset (if any) and checks that the version is recent enough
patchScanAIX () {
	if [ "$patchnum" = "release" ]; then
		considerReleaseAIX
		return
	fi
	while read FILESET VERSION; do
		if [ "$patchnum" != "$FILESET" ]; then continue; fi
		if [ "$patchseq" = "$VERSION" ]; then
			debugmsg "found matching patch $FILESET:$VERSION"
			return 0
		fi
		( echo "$patchseq"; echo "$VERSION"; ) |
			sort -c -n -t . -k 1,1 -k 2,2 -k 3,3 -k 4,4 \
			>/dev/null 2>&1
		if [ $? -eq 0 ]; then
			msg="$NEWERPATCH $FILESET:$VERSION"
			debugmsg "found newer patch $FILESET:$VERSION"
			return 0
		fi
		msg="$OLDERPATCH $FILESET:$VERSION"
		debugmsg "found older patch $FILESET:$VERSION"
	done
	return 1
}

clearPatchData () {
	rm -f "$showrevfile"
}

cachePatchData () {
	if [ -f "$showrevfile" ]; then
		: # we're in gravy
	elif [ "$osname" = "SunOS" -a -x /bin/showrev ]; then
		if [ "$quiet" != "yes" ]; then
			echo "$DOINGSHOWREV"
		fi
		showrev -p | sort -ur |
			sed -e 's/,//g' -e 's/-/ /g' >"$showrevfile"
	elif [ "$osname" = "SunOS" -a -x /usr/sbin/patchadd ]; then
		if [ "$quiet" != "yes" ]; then
			echo "$DOINGSHOWREV (PatchADD)"
		fi
		/usr/sbin/patchadd -p | sort -ur |
			sed -e 's/,//g' -e 's/-/ /g' >"$showrevfile"
	elif [ "$osname" = "SunOS" ]; then
		echo "$0: $NOSHOWREV"
		clearPatchData
		for f in /var/sadm/patch/[0-9]*; do
			f=`basename $f | sed -e 's/-/ /g'`
			echo "Patch: $f Obsoletes:" >>"$showrevfile"
		done
	elif [ "$osname" = "AIX" -a -x /bin/lslpp ]; then
		if [ "$quiet" != "yes" ]; then
			echo "$DOINGSHOWREV"
		fi
		#set LIBPATH for system libz.a
		if [ -d "/opt/freeware/lib/" ]; then
			TEMPLIBPATH=`echo $LIBPATH`
			LIBPATHPREFFIX="/opt/freeware/lib/"
			LIBPATH="$LIBPATHPREFFIX:$TEMPLIBPATH"
			export LIBPATH=$LIBPATH
		fi
		#Run lslpp -lc to gather the list of packages, filter through sed to pass only known characters,
		# parse fields 2 and 3 through awk, and strip off the first line using tail.
		lslpp -lc | sed s/[^A-Za-z0-9\ \\\n\_\:\!@#\$%^\&\*\(\)\\\/\.\,\<\>?+-=\\\'\\\"]*//g |
		awk -F: '{ print $2 " " $3 }' | tail +2 >"$showrevfile"
		if [ -d "/opt/freeware/lib/" ]; then
			#restore LIBPATH to setup
			LIBPATH="$TEMPLIBPATH"
			export LIBPATH=$LIBPATH
		fi
	else
		echo "$0: $NOLSLPP"
		cleanup
		exit 1
	fi
}

scanForPatches () {

	# We need to scan through our list of active patches and look for
	# those that supersede our desired patch

	exec 3<&0 <"$PATCHESINSTALLED"

	while read HPpatch HPrest; do

		#We only need to check supersession for patches of the same type (ie. PHSS, PHCO, PHNE, PHKL)
		case $HPpatch in
		   PHSS*)
		   	# Is it the right type?
		   	if [ "PHSS" = "`echo "$1" | sed 's/\(.*\)_.*/\1/'`" ]; then

		   		# It is the right type, now make sure it's a higher number than our desired
		   		# patch so that we can save the expensive operation of the swlist command
		   		if [ "`echo "$1" | sed 's/.*_\(.*\)/\1/'`" -lt "`echo "$HPpatch" | sed 's/.*_\(.*\)/\1/'`" ]; then

		   			#perform the check
		   			if [ "" != "`/usr/sbin/swlist -a supersedes $HPpatch | grep $1`" ]; then
		   				# found it
						debugmsg "$1 is superseded by $HPpatch"
						exec 0<&3 3<&-
		   				return "0"
		   			fi
		   		fi
		   	fi
			;;
		   PHCO*)
		   	# Is it the right type?
		   	if [ "PHCO" = "`echo "$1" | sed 's/\(.*\)_.*/\1/'`" ]; then

		   		# It is the right type, now make sure it's a higher number than our desired
		   		# patch so that we can save the expensive operation of the swlist command
		   		if [ "`echo "$1" | sed 's/.*_\(.*\)/\1/'`" -lt "`echo "$HPpatch" | sed 's/.*_\(.*\)/\1/'`" ]; then

		   			#perform the check
		   			if [ "" != "`/usr/sbin/swlist -a supersedes $HPpatch | grep $1`" ]; then
		   				# found it
						debugmsg "$1 is superseded by $HPpatch"
						exec 0<&3 3<&-
		   				return "0"
		   			fi
		   		fi
		   	fi
			;;
	 	   PHNE*)
		   	# Is it the right type?
		   	if [ "PHNE" = "`echo "$1" | sed 's/\(.*\)_.*/\1/'`" ]; then

		   		# It is the right type, now make sure it's a higher number than our desired
		   		# patch so that we can save the expensive operation of the swlist command
		   		if [ "`echo "$1" | sed 's/.*_\(.*\)/\1/'`" -lt "`echo "$HPpatch" | sed 's/.*_\(.*\)/\1/'`" ]; then

		   			#perform the check
		   			if [ "" != "`/usr/sbin/swlist -a supersedes $HPpatch | grep $1`" ]; then
		   				# found it
						debugmsg "$1 is superseded by $HPpatch"
						exec 0<&3 3<&-
		   				return "0"
		   			fi
		   		fi
		   	fi
			;;
		   PHKL*)
		   	# Is it the right type?
		   	if [ "PHKL" = "`echo "$1" | sed 's/\(.*\)_.*/\1/'`" ]; then

		   		# It is the right type, now make sure it's a higher number than our desired
		   		# patch so that we can save the expensive operation of the swlist command
		   		if [ "`echo "$1" | sed 's/.*_\(.*\)/\1/'`" -lt "`echo "$HPpatch" | sed 's/.*_\(.*\)/\1/'`" ]; then

		   			#perform the check
		   			if [ "" != "`/usr/sbin/swlist -a supersedes $HPpatch | grep $1`" ]; then
		   				# found it
						debugmsg "$1 is superseded by $HPpatch"
						exec 0<&3 3<&-
		   				return "0"
		   			fi
		   		fi
		   	fi
			;;
		esac
	done

	exec 0<&3 3<&-
	return "1"
}

doPatchQuery () {
	msg=''


	# make sure we've got an argument
	if [ "$1" = "" ]; then
		doUsage
		cleanup
		exit 1
	fi

	# handle the case of a filename or package
	alreadydone=no
	case "$1" in
	  /*)
		test -f "$1"
		rc="$?"
		alreadydone=yes
		;;
	  APAR*)
		if [ "$osname" = "AIX" ]; then
			APAR=`echo "$1" | cut -b 5-`
			/usr/sbin/instfix -i -k "$APAR" -q
			rc="$?"
			alreadydone=yes
		fi
		;;
	  Update*)
	       if [ "$osname" = "Linux" -a -f "/etc/redhat-release" ]; then
		   updatelevel="`cat /etc/redhat-release | sed 's/.*Update \(.*\))/\1/'`"
		   reqlevel="`echo "$1" | sed 's/Update-\(.*\)/\1/'`"
		   testupdate=${updatelevel//[^0-9]/}
		   testreq=${reqlevel//[^0-9]/}
		        if [ "$testupdate" = "$updatelevel" -a "$testreq" = "$reqlevel" ]; then
      		            if [ $updatelevel -ge $reqlevel ]; then
                                rc="0"
				alreadydone=yes
			    fi
                        fi
	       fi
	       ;;
	  PH*)
	       if [ "$osname" = "HP-UX" ]; then
			# Not a bundle, check for individual patches.
	                if [ -f $PATCHESINSTALLED ]; then
		               if [ "" = "`grep $1 $PATCHESINSTALLED`" ]; then
		                     scanForPatches "$1"
		                     rc=$?
				     alreadydone=yes
		               else
		                     rc="0"
		                     alreadydone=yes
			       fi
			else
			       # first time through we want to create our file so that we can just grep it
			       show_patches -sa > $PATCHESINSTALLED
			       if [ "" = "`grep $1 $PATCHESINSTALLED`" ]; then
                                     scanForPatches "$1"
				     rc=$?
				     alreadydone=yes
			       else
				     rc="0"
				     alreadydone=yes
                               fi
	                fi
	       fi
	       ;;
	  [A-Z]*)
	        if [ "$osname" = "HP-UX" ]; then
	        	# Check to see if this was a bundle - Bundles are defined
	        	# <BUNDLENAME>_<VERSION>

	        	# Split into bundle name and bundle version
	        	req_bundlename=`echo $1 | sed 's/\(.*\)_.*/\1/'`
	        	req_bundleversion=`echo $1 | sed 's/.*_\(.*\)/\1/'`

	        	sys_bundleentry=`/usr/sbin/swlist -l bundle | grep $req_bundlename`;

	        	sys_bundlename=`echo "$sys_bundleentry" | awk '{print $1}'`
			   	sys_bundleversion=`echo "$sys_bundleentry" | awk '{print $2}'`

				if [ "" = "$sys_bundleentry" ]; then
				   rc="1"
				   alreadydone=yes
				else
				   # Verify that this is a version that is at least bundle version
				   ( echo "$req_bundleversion"; echo "$sys_bundleversion"; ) | sort -c -n -t - -k 1,1 -k 2,2 >/dev/null 2>&1
				   rc=$?

				   alreadydone=yes
				fi
	        elif [ "$osname" = "SunOS" ]; then
				pkginfo -q "$1"
				rc="$?"
				alreadydone=yes
		elif [ "$osname" = "Linux" ]; then
			if [ "" = "`rpm -q "$1" | grep " "`" ]; then
				rc="0"
				alreadydone=yes
			else
				if [ "" != "`rpm -qa | grep "$1"`" ]; then
					rc="0"
					alreadydone=yes
				else
					rc="1"
					#Now we need to look for newer patches
					name=`echo $1 | sed -e 's/\([A-Za-z0-9+_-]*\)-[0-9]*.*/\1/g'`
					minversion=`echo $1 | sed -e 's/[A-Za-z0-9+_-]*-\([0-9]*.*\)/\1/g' -e 's/-/./g'`
					#remove subarch at end of rpm name if it exists (i.e. i386, fc6, el5)
					minversion=`echo "$minversion" | sed 's/\.[A-Za-z][A-Za-z]*[0-9][0-9]*$//'`
					queryresult=`rpm -q "$name"`
					if [ "" = "`echo "$queryresult" | grep " "`" ]; then
						#We found a patch, now lets check the versioning of it
						haveversion=`echo $queryresult | sed -e 's/[A-Za-z0-9+_-]*-\([0-9]*.*\)/\1/g' -e 's/-/./g'`
	  					#remove subarch at end of rpm name if it exists (i.e. i386, fc6, el5)
						haveversion=`echo "$haveversion" | sed 's/\.[A-Za-z][A-Za-z]*[0-9][0-9]*$//'`
						while [ "$minversion"x != "x" ]; do
							minpart=`echo "$minversion" | sed -e 's/\([0-9]*\).*/\1/g'`
							havepart=`echo "$haveversion" | sed -e 's/\([0-9]*\).*/\1/g'`
							minversion=`echo "$minversion" | sed -e 's/[0-9]*.\(.*\)/\1/g'`
							haveversion=`echo "$haveversion" | sed -e 's/[0-9]*.\(.*\)/\1/g'`
							if [ $minpart -gt $havepart ]; then
								rc="1"
								break
							elif [ $minpart -lt $havepart ]; then
	                                                        rc="0"
	                                                        break
							fi
						done
					fi
					alreadydone=yes
				fi
			fi
		fi
		;;
          [a-z]*)
				if [ "$osname" = "SunOS" ]; then
					env LD_LIBRARY_PATH= pkg info -q "$1"
					rc="$?"
					alreadydone=yes
				elif [ "$osname" = "Linux" ]; then
			if [ "" = "`rpm -q "$1" | grep " "`" ]; then
				rc="0"
				alreadydone=yes
			else
				if [ "" != "`rpm -qa | grep "$1"`" ]; then
					rc="0"
					alreadydone=yes
				else
					rc="1"
					#Now we need to look for newer patches
					name=`echo $1 | sed -e 's/\([A-Za-z0-9+_-]*\)-[0-9]*.*/\1/g'`
					minversion=`echo $1 | sed -e 's/[A-Za-z0-9+_-]*-\([0-9]*.*\)/\1/g' -e 's/-/./g'`
					#remove subarch at end of rpm name if it exists (i.e. i386, fc6, el5)
					minversion=`echo "$minversion" | sed 's/\.[A-Za-z][A-Za-z]*[0-9][0-9]*$//'`
					queryresult=`rpm -q "$name"`
					if [ "" = "`echo "$queryresult" | grep " "`" ]; then
						#We found a patch, now lets check the versioning of it
						haveversion=`echo $queryresult | sed -e 's/[A-Za-z0-9+_-]*-\([0-9]*.*\)/\1/g' -e 's/-/./g'`
	  					#remove subarch at end of rpm name if it exists (i.e. i386, fc6, el5)
						haveversion=`echo "$haveversion" | sed 's/\.[A-Za-z][A-Za-z]*[0-9][0-9]*$//'`
						while [ "$minversion"x != "x" ]; do
							minpart=`echo "$minversion" | sed -e 's/\([0-9]*\).*/\1/g'`
							havepart=`echo "$haveversion" | sed -e 's/\([0-9]*\).*/\1/g'`
							minversion=`echo "$minversion" | sed -e 's/[0-9]*.\(.*\)/\1/g'`
							haveversion=`echo "$haveversion" | sed -e 's/[0-9]*.\(.*\)/\1/g'`
							if [ $minpart -gt $havepart ]; then
								rc="1"
								break
							elif [ $minpart -lt $havepart ]; then
	                                                        rc="0"
	                                                        break
							fi
						done
					fi
					alreadydone=yes
				fi
			fi
		fi
		;;
	esac
	if [ "$alreadydone" = "yes" ]; then
		if [ "$quiet" != "yes" -a "$rc" = "0" ]; then
			echo "$1"
		fi
		if [ "$noexit" = "yes" ]; then return $rc; fi
		cleanup
		exit $rc
	fi

	# parse the bits out of the argument
	fullpatch=$1
	if [ "$osname" = "SunOS" ]; then
		patchnum=`echo $fullpatch | sed -e 's/-.*//'`
		patchseq=`echo $fullpatch | sed -e 's/.*-//'`
	else
		patchnum=`echo $fullpatch | sed -e 's/:.*//'`
		patchseq=`echo $fullpatch | sed -e 's/.*://'`
	fi
	if [ "$specificPFileExists" = "yes" ]; then
		if [ "$patchnum" = "$patchseq" ]; then
			echo "$0: invalid patch name: $fullpatch"
			cleanup
			exit 1
		fi
	fi
	debugmsg "querying patch $fullpatch ($patchnum/$patchseq)"

	# look for the patch
	cachePatchData
	patchScan$osname <"$showrevfile"
	if [ $? -eq 0 ]; then
		if [ "$quiet" = "no" ]; then
			echo $fullpatch
		fi
		rc=0
	else
		rc=1
	fi

	# exit or return as appropriate
	debugmsg "query returning $rc"
	if [ "$noexit" = "yes" ]; then
		return $rc
	else
		clearPatchData
		cleanup
		exit $rc
	fi
}

########################################################################
# check if a whole bunch of patches are installed
# print error messages for non-installed patches if not in quiet mode
# indicate success or failure with the exit code

doPatchCheck () {

	# make sure we've got an argument
	if [ "$1" = "" ]; then
		doUsage
		cleanup
		exit 1
	fi

	specificPFileExists=yes		# if a filename with a specific OS version is not found, then we want to remember this
	# try to more finely hone the filename
	pfile="$1"
	if [ "$1" = "-" ]; then
		: # don't hone stdin
	elif [ "$osname" = "SunOS" -a -r "$1"-`uname -r` ]; then
		pfile="$1"-`uname -r`
	elif [ "$osname" = "AIX" -a -r "$1"-"`uname -v`.`uname -r`" ]; then
		pfile="$1"-`uname -v`.`uname -r`
	elif [ "$osname" = "Linux" ]; then
		if [ -f "/etc/redhat-release" ]; then
			# assume that first period in redhat-release string is after the major version
			patchfilename="$1-`cat /etc/redhat-release | sed 's/Linux \(.*\)release \(.*\) (.*)/\1 \2/' | tr "ABCDEFGHIJKLMNOPQRSTUVWXYZ " "abcdefghijklmnopqrstuvwxyz-" | sed 's/--/-/g' | cut -d. -f 1`"
			if [ -r "$patchfilename" ]; then
				pfile="$patchfilename"
			else
				specificPFileExists=no
			fi
		elif [ -f "/etc/SuSE-release" ]; then
			patchfilename="$1-`cat /etc/SuSE-release | sed -e '2,$d' -e 's/\(.*\) LINUX \(.*\) (.*)/\1 \2/i' | tr "ABCDEFGHIJKLMNOPQRSTUVWXYZ" "abcdefghijklmnopqrstuvwxyz" | sed 's/ /_/g'`"
			# find the patchlevel number
			servicepacklevel="`cat /etc/SuSE-release | sed -n 's/PATCHLEVEL = \(.*\)/\1/p'`"
			if [ -n "$servicepacklevel" ]; then
				debugmsg "SuSE service pack found: sp$servicepacklevel"
				wildcard="$patchfilename"*
				availablepatchlevel="`ls $wildcard 2>/dev/null | sed -n 's/.*-sp\(.\)/\1/p' | sed q`"
				debugmsg "Found service pack level: $availablepatchlevel"
				if [[ $availablepatchlevel -le $servicepacklevel ]]; then
					minimalpatchlevelfile="$patchfilename-sp$availablepatchlevel"
					debugmsg "Looking for $minimalpatchlevelfile"
					if [ -r "$minimalpatchlevelfile" ]; then
						debugmsg "SuSE minimal patchlevel file found: $minimalpatchlevelfile"
						patchfilename="$minimalpatchlevelfile"
					fi
				fi
			fi
			if [ -r "$patchfilename" ]; then
				pfile="$patchfilename"
			else
				specificPFileExists=no
			fi
		elif [ -f "/etc/os-release" ]; then
			patchfilename="$1-`cat /etc/os-release | sed '/PRETTY_NAME/!d' | sed 's/PRETTY_NAME=\"//g; s/ Linux//g; s/\"//g; s/ SP.//g' | tr "ABCDEFGHIJKLMNOPQRSTUVWXYZ" "abcdefghijklmnopqrstuvwxyz" | sed 's/ /_/g'`"
			# find the patchlevel number
			servicepacklevel="`cat /etc/os-release | sed -n 's/VERSION_ID="\(.*\)"/\1/p' | cut -b 4`"
			if [ -n "$servicepacklevel" ]; then
				debugmsg "SuSE service pack found: sp$servicepacklevel"
				wildcard="$patchfilename"*
				availablepatchlevel="`ls $wildcard 2>/dev/null | sed -n 's/.*-sp\(.\)/\1/p' | sed q`"
				debugmsg "Found service pack level: $availablepatchlevel"
				if [[ $availablepatchlevel -le $servicepacklevel ]]; then
					minimalpatchlevelfile="$patchfilename-sp$availablepatchlevel"
					debugmsg "Looking for $minimalpatchlevelfile"
					if [ -r "$minimalpatchlevelfile" ]; then
						debugmsg "SuSE minimal patchlevel file found: $minimalpatchlevelfile"
						patchfilename="$minimalpatchlevelfile"
					fi
				fi
			fi
			if [ -r "$patchfilename" ]; then
				pfile="$patchfilename"
			else
				specificPFileExists=no
			fi
		fi
	elif [ "$osname" = "HP-UX" -a -r "$1"-`uname -r` ]; then
		if [ `uname -m` = "ia64" ]; then
			pfile="$1"-64-`uname -r`
		else
			pfile="$1"-`uname -r`
		fi
	else
		specificPFileExists=no
	fi

	# make sure we've got a readable file now
	if [ ! -r "$pfile" ]; then
		echo "$0: $PATCHFILENOREAD: '$pfile'"
		cleanup
		exit 1
	fi
	debugmsg "using patch file: '$pfile'"

	success=yes

	# scan through the file
	oldquiet="$quiet"
	quiet="yes" noexit="yes"

	# ADAPT00913079, opening the pfile via <$pfile causes HP to hang occasionally
	# the workaround is to use sed to read file line by line

	a=1
	wc=`wc -l "$pfile" | awk '{print $1}'`

	while [ "$a" -le "$wc" ]
	do
		if [ "$specificPFileExists" = "yes" ]; then
			patch=`sed -n -e "$a p" "$pfile" | awk '{print $1}'`
			MSG0="$PATCHMISSING"
		else
			patch=`sed -n -e "$a p" "$pfile" | awk '{print $0}'`
			MSG0="$UNSUPPORTEDPLATFORM"
		fi
		a=`expr $a + 1`		# increment counter

		MSG1="$PATCHFOUND"
		case "$patch" in
		  /*)
			MSG0="$FILEMISSING"
			MSG1="$FILEFOUND"
			;;
		  [A-Z]*)
			if [ "$osname" = "SunOS" ]; then
				if [ "$specificPFileExists" = "yes" ]; then
					MSG0="$PKGMISSING"
				fi
				MSG1="$PKGFOUND"
			fi
			;;
		esac

		if [ "$patch" = "" ]; then continue; fi

		doPatchQuery "$patch"

		if [ $? -eq 0 ]; then
			if [ "$verbose" = "yes" ]; then
				echo "$MSG1: $patch $rest"
				if [ "$msg" != "" ]; then
					echo "  ($msg)"
				fi
			fi
		else
			success=no
			if [ "$oldquiet" != "yes" ]; then
				echo "$MSG0: $patch $rest"
				if [ "$msg" != "" ]; then
					echo "  ($msg)"
				fi
			fi
		fi
	done

	# did it all go well?
	clearPatchData
	cleanup
	if [ "$success" = "yes" ]; then
		exit 0;
	else
		exit 1;
	fi
}


########################################################################
# here we go with the main part of the script

# default to being noisy
quiet=no
verbose=no
debug=no

while [ "$1" != "" ]; do
	if [ "$1" = "-q" ]; then
		quiet=yes
	elif [ "$1" = "-v" ]; then
		verbose=yes
	elif [ "$1" = "-d" ]; then
		debug=yes
	elif [ "$1" = "query" ]; then
		doPatchQuery "$2"
		shift
	elif [ "$1" = "list" ]; then
		cachePatchData
		if [ "$osname" = "SunOS" ]; then
			awk '{ print $2 "-" $3 }'
		else cat; fi <"$showrevfile" | sort -u
		clearPatchData
	elif [ "$1" = "check" ]; then
		doPatchCheck "$2"
		shift
	else
		doUsage
		cleanup
		exit 1
	fi
	shift
done
cleanup
exit

# EOF

