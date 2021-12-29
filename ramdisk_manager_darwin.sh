#!/usr/local/bin/bash
# ============================================================================
# Titolo: manage_ramdisk.sh
# Descrizione: Provvede all'inizializzazione e gestione di un ramdisk
# Autore: Alfredo Milani
# Data: Gio 20 Set 2018 12:40:51 CEST
# Licenza: MIT License
# Versione: 2.0.0
# Note: --/--
# Versione bash: 4.4.19(1)-release
# ============================================================================

# Colori
declare -r R='\033[0;31m' # red
declare -r Y='\033[1;33m' # yellow
declare -r G='\033[0;32m' # green
declare -r DG='\033[1;30m' # dark gray
declare -r U='\033[4m' # underlined
declare -r BD='\e[1m' # Bold
declare -r NC='\033[0m' # No Color

# Exit status
declare -r -i EXIT_SUCCESS=0
declare -r -i EXIT_FAILURE=1
declare -r -i EXIT_HDIUTIL_ERR=2
declare -r -i EXIT_DISKUTIL_PART_ERR=3
declare -r -i EXIT_NEWFSAPFS_ERR=4
declare -r -i EXIT_DISKUTIL_MOUNT_ERR=5
declare -r -i EXIT_RAMDISK_SYNTAX_ERR=6
declare -r -i EXIT_HELP_REQUESTED=7
declare -r -i EXIT_NO_ARGS=8
declare -r -i EXIT_MISSING_PERMISSION=9

# Readonly vars
declare -r LOG='/var/log/ramdisk_manager.log'
declare -r OS_MACOS='darwin'
declare -r OS_V="${OSTYPE}"
declare -r DEV_NULL='/dev/null'

# Setup's paths
declare -r scripts_sys_path='/Library/Scripts/UtilityScripts'
declare -r launch_daemons_sys_path='/System/Library/LaunchDaemons'
declare download_path='/Users/%s/Downloads'
declare daemon_name='it.%s.ramdisk.manager'
declare -r daemon_ext='.plist'

declare username
declare script_name
declare script_filename

declare links_dir='.Links'
declare links=()
declare retrieved_links_from_plist=()
declare -i ramdisk_size
declare ramdisk_name
declare ramdisk_mount_point
declare permanent_ramdisk_path
declare trash_dirname='Trash'

# Azioni possibili
declare ask=true
declare create_ramdisk_op=false
declare setup_ramdisk_op=false
declare unload_service_op=false
declare create_link_Download_op=false
declare check_deps_op=true
declare check_csr_op=true
declare create_trash_op=false
declare link_health_op=false
declare rebuild_links_op=false
declare backup_ramdisk_op=false
declare restore_ramdisk_op=false


function log {
	printf "${1}\n" >> "${LOG}"
}

function msg {
	case "${1}" in
		G ) printf "${G}${2}${NC}\n" ;;
		Y ) printf "${Y}${2}${NC}\n" ;;
		R ) printf "${R}${2}${NC}\n" ;;
		DG ) printf "${DG}${2}${NC}\n" ;;
		U ) printf "${U}${2}${NC}\n" ;;
		BD ) printf "${BD}${2}${NC}\n" ;;
		* ) printf "${NC}${2}\n" ;;
	esac
}

function get_response {
	msg "${1}" "${2}\t[ S / N ]"

	local choose
	read -e choose
	if [[ "${choose}" == [sS] ]]; then
		return ${EXIT_SUCCESS}
	else
		return ${EXIT_FAILURE}
	fi
}

function check_tools {
	local tools_missing=false

	while [[ ${#} -gt 0 ]]; do
		command -v "${1}" &> "${DEV_NULL}"
		if [[ ${?} != 0 ]]; then
			msg 'R' "Il tool ${1}, necessario per l'esecuzione di questo script, non è presente nel sistema.\nInstallarlo per poter continuare."
			tools_missing=true
		fi
		shift
	done

	[[ "${tools_missing}" == true ]] && return ${EXIT_FAILURE} || return ${EXIT_SUCCESS}
}

function check_os {
	if [[ "${OS_V}" != "${OS_MACOS}"* ]]; then
		msg 'R' "ERRORE: Questo tool può essere lanciato solo da sistemi MacOSX."
		return ${EXIT_FAILURE}
	fi
}

function get_csr_status {
	local status="$(csrutil status | awk '{ print $5 }')"
	local enabled_value="enabled"

	if [[ "${status:0:${#enabled_value}}" == "${enabled_value}" ]]; then
		return ${EXIT_SUCCESS}
	else
		return ${EXIT_FAILURE}
	fi
}

function check_root {
	local -i current_user=$(id -u)
	local -i root_user=0

	if [[ ${current_user} -ne ${root_user} ]]; then
		msg 'R' "Questo tool deve essere lanciato con privilegi di amministratore"
		return ${EXIT_MISSING_PERMISSION}
	fi

	return ${EXIT_SUCCESS}
}

function create_script {
	# Controllo esistenza directory
	if ! [[ -d "${scripts_sys_path}" ]]; then
		msg 'Y' "La directory ${scripts_sys_path} non esiste."
		if [[ "${ask}" == true ]] && ! get_response 'Y' "Crearla?"; then
			msg 'Y' "La directory non è stata creata."
			return ${EXIT_FAILURE}
		fi
		# Creazione directory
		mkdir -p "${scripts_sys_path}"
	fi

	# Controllo se lo script esiste già nella directory di destinazione
	if [[ -f "${scripts_sys_path}/${script_name}" ]]; then
		msg 'Y' "Il file ${scripts_sys_path}/${script_name} esiste."
		if [[ "${ask}" == true ]] && ! get_response 'Y' "Sovrascriverlo?"; then
			msg 'Y' "Il file non è stato sovrascitto."
			return ${EXIT_FAILURE}
		fi
	fi

	# Copia script in una posizione di sistema
	if ! cp "${script_filename}" "${scripts_sys_path}"; then
		msg 'R' "Errore durante la copia del file ${script_filename} in ${scripts_sys_path}/${script_name}"
		return ${EXIT_FAILURE}
	fi

	# Cambio proprietario e gruppo
	chown root:wheel "${scripts_sys_path}/${script_name}"
	# Impostazione permessi di esecuzione
	chmod +x "${scripts_sys_path}/${script_name}"
}

# ${@} -> directories da cui rimuove tutti i files
function rm_all {
	while [[ ${#} -gt 0 ]]; do
		if [[ -d "${1}" && -w "${1}" ]]; then
			rm -rf "${1}/"..?* "${1}/".[!.]* "${1}/"* "${1}/"~* &> "${DEV_NULL}"
		else
			echo "Argomento \"${1}\" non valido."
		fi
		shift
	done
}

function create_and_launch_plist {
	if ! [[ -d "${launch_daemons_sys_path}" ]]; then
		msg 'R' "ERRORE: La directory di sistema ${launch_daemons_sys_path} non esiste."
		return ${EXIT_FAILURE}
	fi

	local plist_file="${launch_daemons_sys_path}/${daemon_name}${daemon_ext}"

	# Controllo se il file plist esiste già nella directory di destinazione
	if [[ -f "${plist_file}" ]]; then
		msg 'Y' "Il file ${plist_file} esiste."
		if [[ "${ask}" == true ]] && ! get_response 'Y' "Sovrascriverlo?"; then
			msg 'Y' "Il file non è stato sovrascitto."
			return ${EXIT_FAILURE}
		fi
		# Unload vecchio file *.plist
		launchctl unload -w "${plist_file}" &> "${DEV_NULL}"
	fi

	local plist_file_content
	read -r -d '' plist_file_content << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
	<dict>
		<key>UserName</key>
		<string>root</string>
		<key>GroupName</key>
		<string>wheel</string>
		<key>InitGroups</key>
		<true/>

		<key>RunAtLoad</key>
		<true/>
		<key>KeepAlive</key>
		<false/>
		<key>LaunchOnlyOnce</key>
		<true/>

		<key>Label</key>
		<string>${daemon_name}</string>

		<key>Program</key>
		<string>${scripts_sys_path}/${script_name}</string>

		<key>ProgramArguments</key>
		<array>
			<string>${scripts_sys_path}/${script_name}</string>
			<string>--create-ramdisk</string>
			<string>${ramdisk_name}</string>
			<string>${ramdisk_mount_point}</string>
			<string>${ramdisk_size}</string>
			<string>--yes</string>
			<string>--jump-deps-check</string>
			<string>--jump-csr-check</string>
			<string>--restore-ramdisk</string>
			<string>${ramdisk_mount_point}</string>
			<string>${permanent_ramdisk_path}</string>
$(
	if [[ "${create_link_Download_op}" == true ]]; then
		printf '\t\t\t<string>%s</string>\n' '--set-user-profile'
		printf '\t\t\t<string>%s</string>\n' "${username}"
		printf '\t\t\t<string>%s</string>\n' '--create-link-in-Download'
	fi
	if [[ "${create_trash_op}" == true ]]; then
		printf '\t\t\t<string>%s</string>\n' '--create-trash'
	fi
	if [[ "${#links[@]}" -gt 0 ]]; then
		local IFS=':'
		printf '\t\t\t<string>%s</string>\n' '--create-links-from'
		printf '\t\t\t<string>%s</string>\n' "${links[*]}"
	fi
)
		</array>
	</dict>
</plist>
EOF
	# Creazione file plist nella directory di sistema
	tee <<< "${plist_file_content}" "${plist_file}" 1> "${DEV_NULL}"

	# Cambio proprietario e gruppo
	chown root:wheel "${plist_file}"
	# Imposto il caricamento automatico all'avvio del sistema
	launchctl load -w "${plist_file}"
}

# ${1} -> hierarchy
# ${2} -> key
# ${3} -> file
# ${retrieved_links_from_plist} -> variabile globale di tipo array
function get_links {
	local -i i=1
	local found=false
	local tmp
	while : ; do
		tmp="$(xmllint --xpath "${1}[${i}]/text()" "${3}")";
		if [[ "${found}" == true ]]; then
			local IFS=':'
			retrieved_links_from_plist=(${tmp})
			break
		elif [[ "${tmp}" == "${2}" ]]; then
			found=true
		elif [[ -z "${tmp}" ]]; then
			break
		fi

		i=$((++i))
	done
}

# ${1} -> hierarchy
# ${2} -> key
# ${3} -> file
# ${ramdisk_mount_point} -> variabile globale di tipo array
function get_mount_point {
	local -i i=1
	local found=false
	local tmp
	while : ; do
		tmp="$(xmllint --xpath "${1}[${i}]/text()" "${3}")";
		if [[ "${found}" == true ]]; then
			local v1="$(xmllint --xpath "${1}[${i}]/text()" "${3}")";
			i=$((++i))
			local v2="$(xmllint --xpath "${1}[${i}]/text()" "${3}")";
			i=$((++i))
			local v3="$(xmllint --xpath "${1}[${i}]/text()" "${3}")";
			
			ramdisk_mount_point="${v2}"
			break
		elif [[ "${tmp}" == "${2}" ]]; then
			found=true
		elif [[ -z "${tmp}" ]]; then
			break
		fi

		i=$((++i))
	done
}

function rebuild_links {
	msg 'NC' "Rebuilding links"

	local plist_file="${launch_daemons_sys_path}/${daemon_name}${daemon_ext}"
	if ! [[ -f "${plist_file}" ]]; then
		msg 'Y' "Il file ${plist_file} non esiste quindi non è possibile eliminare i links creati in precedenza."
		return ${EXIT_FAILURE}
	fi

	# Eliminio tutte le cartelle nel ramdisk
	rm_all "${ramdisk_mount_point}"
	get_links '/plist/dict/array/string' '--create-links-from' "${plist_file}"
	get_mount_point '/plist/dict/array/string' '--create-ramdisk' "${plist_file}"
	create_links "${retrieved_links_from_plist[@]}" || return ${EXIT_FAILURE}

	return ${EXIT_SUCCESS}
}

function unload_links {
	msg 'NC' 'Sostituzione links simbolici con directories'

	local plist_file="${launch_daemons_sys_path}/${daemon_name}${daemon_ext}"
	if ! [[ -f "${plist_file}" ]]; then
		msg 'Y' "Il file ${plist_file} non esiste quindi non è possibile eliminare i links creati in precedenza."
		return ${EXIT_FAILURE}
	fi

	get_links '/plist/dict/array/string' '--create-links-from' "${plist_file}"
	for link in "${retrieved_links_from_plist[@]}"; do
		if [[ -L "${link}" ]]; then
			msg 'NC' "\tRimozione link: ${link}"
			rm -rf "${link}" || return ${EXIT_FAILURE}
			mkdir "${link}" || return ${EXIT_FAILURE}
		fi
	done

	return ${EXIT_SUCCESS}
}

function unload_script {
	msg 'NC' 'Eliminazione script per la gestione del ramdisk.'

	# Eliminazione script
	rm -f "${scripts_sys_path}/${script_name}" || return ${EXIT_FAILURE}
}

function unload_plist {
	msg 'NC' 'Eliminazione servizio per la gestione ramdisk'

	# Disabilitazione caricamento automatico
	launchctl unload -w "${launch_daemons_sys_path}/${daemon_name}${daemon_ext}" &> "${DEV_NULL}" || return ${EXIT_FAILURE}
	# Rimozione file *.plist
	rm -f "${launch_daemons_sys_path}/${daemon_name}${daemon_ext}" || return ${EXIT_FAILURE}
}

function remove_volume {
	diskutil umount "${ramdisk_mount_point}" || return ${EXIT_FAILURE}
	rmdir "${ramdisk_mount_point}" || return ${EXIT_FAILURE}

	return ${EXIT_SUCCESS}
}

function unload_service {
	unload_links || return ${EXIT_FAILURE}
	unload_script || return ${EXIT_FAILURE}
	unload_plist || return ${EXIT_FAILURE}
	remove_volume || return ${EXIT_FAILURE}

	return ${EXIT_SUCCESS}
}

function setup_ramdisk {
	create_script
	create_and_launch_plist
}

# ${1} -> disco da smontare ed espellere (e.g. disk7)
function on_create_ramdisk_error {
	msg 'NC' "Rimozione disco \"${1}\""
	if [[ "${ask}" == true ]] && ! get_response 'Y' "Continuare?"; then
		msg 'Y' "La rimozione non è stata effettuata"
		return ${EXIT_FAILURE}
	fi

	local dev='/dev'
	diskutil umountDisk "${dev}/${1}"
	diskutil eject "${dev}/${1}"

	return ${EXIT_SUCCESS}
}

# ${1} -> ramdisk name
# ${2} -> ramdisk mount point
# ${3} -> ramdisk size in MB
function create_ramdisk {
	local disk="$(basename $(hdiutil attach "ram://$((${3} * 2 << 10))" -nomount -noverify -nobrowse))"
	if [[ -z "${disk}" ]]; then
		msg 'R' "ERRORE: hdiutil - creazione disco per il ramdisk"
		return ${EXIT_HDIUTIL_ERR}
	fi

	diskutil partitionDisk "${disk}" GPT APFS %noformat% R
	if [[ ${?} -ne ${EXIT_SUCCESS} ]]; then
		msg 'R' "ERRORE: diskutil - partizionamento disco ${disk}"
		on_create_ramdisk_error "${disk}"
		return ${EXIT_DISKUTIL_PART_ERR}
	fi

	newfs_apfs -v "${1}" "${disk}s1"
	if [[ ${?} -ne ${EXIT_SUCCESS} ]]; then
		msg 'R' "ERRORE: newfs_apfs - creazione APFS sul disco ${disk}s1"
		on_create_ramdisk_error "${disk}"
		return ${EXIT_NEWFSAPFS_ERR}
	fi

	diskutil mount -mountPoint "${2}" "${1}"
	if [[ ${?} -ne ${EXIT_SUCCESS} ]]; then
		msg 'R' "ERRORE: diskutil - creazione punto di mount ramdisk"
		on_create_ramdisk_error "${disk}"
		return ${EXIT_DISKUTIL_MOUNT_ERR}
	fi

	return ${EXIT_SUCCESS}
}

function check_links_health {
	local plist_file="${launch_daemons_sys_path}/${daemon_name}${daemon_ext}"
	if ! [[ -f "${plist_file}" ]]; then
		msg 'Y' "Il file ${plist_file} non esiste quindi non è possibile controllare lo stato dei links."
		return ${EXIT_FAILURE}
	fi

	get_links '/plist/dict/array/string' '--create-links-from' "${plist_file}"

	local links_health
	read -r -d '' links_health << EOF
${BD}${U}#${NC}:${BD}${U}Source${NC}:${BD}${U}Status source${NC}:${BD}${U}Link${NC}:${BD}${U}Status link${NC}
$(
	local -i i=0
	for link in "${retrieved_links_from_plist[@]}"; do
		local source_path="$(readlink "${link}")"
		if [[ -z "${source_path}" ]]; then
			source_path="${R}--/--${NC}"
		fi
		
		local source_status
		if [[ -e "${source_path}" ]]; then
			source_status="${G}Good${NC}"
		else
			source_status="${R}Not existing${NC}"
		fi

		local link_status
		if [[ -e "${link}" && -L "${link}" ]]; then
			link_status="${G}Good${NC}"
		else
			link_status="${R}Broken${NC}"
		fi

		i=$((++i))
		printf "${BD}${U}${i}${NC}:${source_path}:${source_status}:${link}:${link_status}\n"
	done
)
EOF

	msg 'BD' "Controllo salute links per l'utente \"${username}\"${NC} - ${plist_file}"
	msg 'NC' "${links_health}" | column -t -s ':'

	return ${EXIT_SUCCESS}
}

function create_links {
	# La creazione della directory contenente i links è disaccoppiata dal creazione
	#  dello stesso in essa per validare il nome della directory scelta
	if ! [[ -d "${ramdisk_mount_point}/${links_dir}" ]]; then
		mkdir "${ramdisk_mount_point}/${links_dir}" || return ${EXIT_FAILURE}
	fi

	while [[ ${#} -gt 0 ]]; do
		# Creo la directory nel ramdisk
		mkdir -p "${ramdisk_mount_point}/${links_dir}/${1}" || return ${EXIT_FAILURE}

		# Controllo se ${1} (che rappresenta il file) da sostituire con un link sia già un link e 
		#  in caso negativo elimino la directory e creo il link
		if [[ ! -e "${1}" || "$(readlink "${1}")" != "${ramdisk_mount_point}/${links_dir}/${1}" ]]; then
		 	rm -rf "${1}" || return ${EXIT_FAILURE}
			ln -s "${ramdisk_mount_point}/${links_dir}/${1}" "${1}" || return ${EXIT_FAILURE}
		fi

		shift
	done

	return ${EXIT_SUCCESS}
}

function backup_ramdisk {
	rsync -a --delete --exclude=".*" "${ramdisk_mount_point}/" "${permanent_ramdisk_path}" || return ${EXIT_FAILURE}

	return ${EXIT_SUCCESS}
}

function restore_ramdisk {
	local files=("${permanent_ramdisk_path}"/*)
	if [[ -d "${permanent_ramdisk_path}" && (( ${#files[*]} )) ]]; then
		rsync -a --exclude=".*" "${permanent_ramdisk_path}/" "${ramdisk_mount_point}"
	fi

	return ${EXIT_SUCCESS}
}

function usage {
	local usage
	read -r -d '' usage << EOF
${BD}### Utilizzo${NC}
	
	${script_name} -[options]

	Questo script può essere usato per configurare un ramdisk creato in modo 
	automatico all'avvio del sistema.

${BD}### Options${NC}

	-b ${U}ramdisk_mount_point${NC} ${U}permanent_ramdisk_path${NC} | --backup-ramdisk ${U}ramdisk_mount_point${NC} ${U}permanent_ramdisk_path${NC}
		Crea un backup del contenuto del ramdisk nella posizione specificata ${U}permanent_ramdisk_path${NC}.

	-c ${U}ramdisk_name${NC} ${U}ramdisk_mount_point${NC} ${U}ramdisk_size_MB${NC} | --create-ramdisk ${U}ramdisk_name${NC} ${U}ramdisk_mount_point${NC} ${U}ramdisk_size_MB${NC}
		Inizializza un ramdisk creando un disco di nome ${U}ramdisk_name${NC} di dimensione ${U}ramdisk_size_MB${NC} che
		verrà montato in ${U}ramdisk_mount_point${NC}.

	-d | --create-link-to-Download
		Crea un link nella direcotry download che punta al punto di mount del ramdisk creato.

	-f ${U}file_list${NC} | --create-links-from ${U}file_list${NC}
		Una volta creato il ramdisk elimina le directories specificate e crea un link
		simbolico delle stesse all'interno del ramdisk.
		Il contenuto delle directories verrà eliminato.
		Il parametro ${U}file_list${NC} deve avere il seguente formato:

		"/path_uno/directory_uno:/path_due/directory_due/:/path_tre/directory_tre"

	-i | --jump-csr-check
		Questo tool di default controlla se è attivo il CSR (System Integrity Protection) e in tal caso termina la sua esecuzione.
		Non in tutte le istanza di esecuzione è necessaria la disabilitazione del CSR.
		Se, ad esempio, dovrà essere creato un link della directory di sistema "/System/Library/Caches",
		sarà necessario disabilitare il CSR per completare l'operazione di scrittura.

		Dal momento che non sempre è necessaria la disabilitazione del CSR, è possibile utilizzare il flag -i per permettere a questo tool
		di operare senza controllare lo stato del CSR.

		Da notare che una volta che si è impostato lo script in avvio automatico, è possibile riabilitare il CSR perché lo script viene
		eseguito all'avvio dall'utente root:wheel.

	-j | --jump-deps-check
		Disabilitazione controllo dipendenze tools ausiliari.

	-l | --link-health
		Legge il file che gestisce il servizio di creazione del ramdisk contenuto nella directory ${launch_daemons_sys_path}
		e verifica la salute di tutti i links specificiati dal comando --filenames-to-create.

	-n ${U}directory_name${NC} | --links-dir-name ${U}directory_name${NC}
		Imposta il nome della directory nella quale creare i links simbolici nel ramdisk.
		Il valore di default è "${links_dir}".

	-p ${U}username${NC} | --set-user-profile ${U}username${NC}
		Specifica lo username che si vuole utilizzare.
		Questa opzione è utile per impostare correttamente i path che vengono usati con il flag -d e -s.

	-r | --rebuild-links
		Ricostruisce i links leggendo il file *.plist associato, quindi è necessario utilizzare il flag -p per specificare 
		l'username dell'utente per il quale è stato generato il ramdisk.
		Nota: il ramdisk non viene rigenerato; saranno solo rigenerati i links.

	-R ${U}ramdisk_mount_point${NC} ${U}permanent_ramdisk_path${NC} | --restore-ramdisk ${U}ramdisk_mount_point${NC} ${U}permanent_ramdisk_path${NC}
		Ripristina il contenuto del ramdisk spostando i dati dalla posizione ${U}permanent_ramdisk_path${NC} verso ${U}ramdisk_mount_point${NC}.

	-s ${U}ramdisk_name${NC} ${U}ramdisk_mount_point${NC} ${U}ramdisk_size_MB${NC} | --setup-ramdisk-at-boot ${U}ramdisk_name${NC} ${U}ramdisk_mount_point${NC} ${U}ramdisk_size_MB${NC}
		Inizializza i files necessari per la creazione del ramdisk all'avvio del sistema.
		Il ramdisk verrà inizializzato creando un disco di nome ${U}ramdisk_name${NC} di dimensione ${U}ramdisk_size_MB${NC} che
		verrà montato in ${U}ramdisk_mount_point${NC}.

	-t | --create-trash
		Crea la directory "Trash" all'interno della directory dove è stato montato il ramdisk

	-u | --unload-script
		Esegue queste operazioni:
			1. rimuove i links simbolici creati e riscostruisce le directory precedenti;
			2. rimuove lo script ${script_name} dalla directory ${scripts_sys_path};
			3. disabilita il servizio per la creazione automatica di un ramdisk e rimuove
				il file *.plist dalla directory ${launch_daemons_sys_path};

	-y | --yes
		Non chiede il permesso dell'utente prima di eseguire un'operazione.

${BD}### Esempio di utilizzo${NC}

	$ ${script_name} -c Ramdisk /Volumes/Ramdisk 1000

		Crea un un volume di nome "Ramdisk", con punto di mount in /Volumes/Ramdisk e di dimensione 1000 MB.

	$ ${script_name} -s Ramdisk /Volumes/Ramdisk 1000 -f "/Library/Caches:/Library/Logs" -f "/System/Library/Caches" -f "/private/tmp"

		Crea un un volume di nome "Ramdisk", con punto di mount in /Volumes/Ramdisk e di dimensione 1000 MB.
		Sostituisce quindi le directories /Library/Caches, /Library/Logs, /System/Library/Caches, /private/tmp con dei links con origine
		nel ramdisk appena creato.
		Il contenuto delle directories verrà eliminato.

	$ sudo ${script_name} -t -d -p ${USER} -f "/Library/Caches:/Library/Logs:/Users/${USER}/Library/Caches" -s Ramdisk /Volumes/Ramdisk 1000 -R /Volumes/Ramdisk "${HOME}/Downloads/tmp/Ramdisk"

		Crea un file *.plist nella directory ${launch_daemons_sys_path} e copia questo script nella posizione ${scripts_sys_path}.
		Così facendo verrà creato un volume di nome "Ramdisk", con punto di mount in /Volumes/Ramdisk e di dimensione 1000 MB, inoltre verrà
		creato un link simbolico del punto di mount nella directory /Users/${USER}/Download/ e verrà creato una directory di nome "Trash"
		all'interno del Ramdisk.
		Le directories /Library/Caches, /Library/Logs e /Users/${USER}/Library/Caches saranno sostituite con dei link simbolici che puntano a
		directories all'interno del ramdisk, quindi in questo caso saranno eliminate le directories /Library/Caches, /Library/Logs e
		/Users/${USER}/Library/Caches, saranno create le direcotries /Volumes/Ramdisk/.Links/Library/Caches, /Volumes/Ramdisk/.Links/Library/Logs e
		/Volumes/Ramdisk/.Links/Users/${USER}/Library/Caches e sarà creato un link simbolico delle directories contenute in /Volumes/Ramdisk/.Links/
		nella posizione di origine (specificate dal flag -f). Il contenuto delle directories verrà eliminato.
		In fase di startup del terminale se la cartella "${HOME}/Downloads/tmp/Ramdisk" esiste e è non vuota, il suo contenuto verrà copiato in "/Volumes/Ramdisk".
\n
EOF

	printf "${usage}"
}

function parse_input {
	if [[ ${#} -eq 0 ]]; then
		msg 'R' "ERRORE: Non è stato specificato alcun argomento."
		usage
		return ${EXIT_NO_ARGS}
	fi

	while [[ ${#} -gt 0 ]]; do
		case "${1}" in
			-b | --backup-ramdisk )
				shift
				ramdisk_mount_point="${1}"
				permanent_ramdisk_path="${2}"
				backup_ramdisk_op=true
				shift 2
				;;

			-c | --create-ramdisk )
				shift
				ramdisk_name="${1}"
				ramdisk_mount_point="${2}"
				ramdisk_size="${3}"
				create_ramdisk_op=true
				shift 3
				;;

			-d | --create-link-in-Download )
				create_link_Download_op=true
				shift
				;;

			-f | --create-links-from )
				shift
				local IFS=':'
				links+=(${1})
	        	shift
				;;

			-[hH] | -help | -HELP | --help | --HELP )
				usage
				return ${EXIT_HELP_REQUESTED}
				;;

			-i | --jump-csr-check )
				check_csr_op=false
				shift
				;;

			-l | --link-health )
				link_health_op=true
				shift
				;;

			-n | --links-dir-name )
				shift
				links_dir="${1}"
				shift
				;;

			-j | --jump-deps-check )
				check_deps_op=false
				shift
				;;

			-p | --set-user-profile )
				shift
				username="${1}"
				shift
				;;

			-r | --rebuild-links )
				rebuild_links_op=true
				shift
				;;

			-R | --restore-ramdisk )
				shift
				ramdisk_mount_point="${1}"
				permanent_ramdisk_path="${2}"
				restore_ramdisk_op=true
				shift 2
				;;

			-s | --setup-ramdisk-at-boot )
				shift
				ramdisk_name="${1}"
				ramdisk_mount_point="${2}"
				ramdisk_size="${3}"
				setup_ramdisk_op=true
				shift 3
				;;

			-t | --create-trash )
				create_trash_op=true
				shift
				;;

			-u | --unload-script )
				unload_service_op=true
				shift
				;;

			-y | --yes )
				ask=false
				shift
				;;

			* )
				msg 'R' "ERRORE: Opzione \"${1}\" non valida."
				return ${EXIT_FAILURE}
				;;
		esac
	done

	return ${EXIT_SUCCESS}
}

function validate_input {
	# Non possono essere specificate entrambi i flags contemporaneamente
	if [[ "${create_ramdisk_op}" == true && "${setup_ramdisk_op}" == true ]]; then
		msg 'R' "ERRORE: Non è possibile specificare contemporaneamente i flags -c e -s."
		return ${EXIT_FAILURE}
	fi

	if [[ "${unload_service_op}" == true ]] && [[ "${create_ramdisk_op}" == true || "${setup_ramdisk_op}" == true ]]; then
		msg 'R' "ERRORE: Non è possibile specificare contemporaneamente i flags -c e -u, -s e -u."
		return ${EXIT_FAILURE}
	fi

	if [[ "${rebuild_links_op}" == true ]] &&
		[[ "${create_ramdisk_op}" == true || "${setup_ramdisk_op}" == true || "${unload_service_op}" == true ]]; then
		msg 'R' "ERRORE: Non è possibile specificare il flag -r ed un altro flag."
		return ${EXIT_FAILURE}
	fi

	if [[ "${create_ramdisk_op}" == true || "${setup_ramdisk_op}" == true ]]; then
		# Informazioni necessarie sia per creare un ramdisk che per il setup all'avvio del sistema
		if [[ ${ramdisk_size} -le 0 ]]; then
			msg 'R' "ERRORE: La dimensione del ramdisk non può essere <= 0"
			return ${EXIT_RAMDISK_SYNTAX_ERR}
		elif [[ -z "${ramdisk_name}" ]]; then
			msg 'R' "ERRORE: Il nome del ramdisk non può essere vuoto"
			return ${EXIT_RAMDISK_SYNTAX_ERR}
		elif [[ -z "${ramdisk_mount_point}" ]]; then
			msg 'R' "ERRORE: Il punto di mount del ramdisk non può essere vuoto"
			return ${EXIT_RAMDISK_SYNTAX_ERR}

		elif [[ "${create_ramdisk_op}" == true && ! -d "${ramdisk_mount_point}" ]]; then
			msg 'NC' "Creazione directory su cui montare il ramdisk - \"${ramdisk_mount_point}\""
			if [[ "${ask}" == true ]] && ! get_response 'Y' "Continuare?"; then
				msg 'Y' "La crezione del punto di mount non è stata effettuata"
				return ${EXIT_FAILURE}
			fi
			mkdir -p "${ramdisk_mount_point}" || return ${EXIT_FAILURE}
		fi
	fi

	# Necessario specificare lo username per risolvere correttamente i paths
	if [[ "${create_link_Download_op}" == true || "${setup_ramdisk_op}" == true || 
		"${unload_service_op}" == true ]] && [[ -z "${username}" ]]; then		
		msg 'R' "ERRORE: Il campo username NON può essere vuoto.\nUtilizzare il flag -p username."
		return ${EXIT_FAILURE}
	fi

	if [[ "${backup_ramdisk_op}" == true || "${restore_ramdisk_op}" == true ]]; then
		if [[ ! -d "${permanent_ramdisk_path}" ]]; then
			msg 'R' "ERRORE: La directory specificata per la persistenza dei dati non esiste."
			return ${EXIT_FAILURE}
		elif [[ -z "${ramdisk_mount_point}" ]]; then
			msg 'R' "ERRORE: Specificare il punto di mount del ramdisk da considerare"
			return ${EXIT_FAILURE}
		fi
	fi

	return ${EXIT_SUCCESS}
}

function lazy_init_tool_vars {
	script_name="$(basename "${0}")"
 	script_filename="${0}"
}

function lazy_init_vars {
	# Dopo aver validato l'input, se non è stato specificato
	#  alcun utente con il flag -p, assumo che l'${username}
	#  sia l'utente chiamante
	if [[ -z "${username}" ]]; then
		username="$(whoami)"
	fi

	download_path="$(printf "${download_path}" "${username}")"
	daemon_name="$(printf "${daemon_name}" "${username}")"
}

function create_link_Download {
	ln -s "${ramdisk_mount_point}" "${download_path}"
	return ${EXIT_SUCCESS}
}

function create_trash {
	mkdir "${ramdisk_mount_point}/${trash_dirname}"
	return ${EXIT_SUCCESS}
}

# ${1} -> main return code
function on_exit {
	if [[ ${1} -ne ${EXIT_HELP_REQUESTED} && ${1} -ne ${EXIT_NO_ARGS} && ${1} -ne ${EXIT_MISSING_PERMISSION} ]]; then
		if [[ ${1} -eq ${EXIT_SUCCESS} ]]; then
			msg 'G' "Operazioni eseguite con successo."
		else
			msg 'R' "Qualcosa è andato storto."
		fi
	fi
	exit ${1}
}

<<COMM
Utilizzare questi flags per creare il file *.plist, lo script in una
posizione di sistema e caricare lo script all'avvio del sistema:
sudo ${script_filename} -t -p "${USER}" -s "Ramdisk" "/Volumes/Ramdisk" 1000 \
-f "/Library/Caches:/Library/Logs" \
-f "/System/Library/Caches:/System/Library/CacheDelete" \
-f "/private/tmp:/private/var/log:/private/var/tmp" \
-f "${HOME}/Library/Logs:${HOME}/Library/Caches:${HOME}/.cache" \
-f "${HOME}/Library/Application Support/Google/Chrome/Default/Application Cache:${HOME}/Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage" \
-f "${HOME}/Library/Application Support/Google/Chrome/Profile 1/Application Cache:${HOME}/Library/Application Support/Google/Chrome/Profile 1/Service Worker/CacheStorage" \
-f "${HOME}/Library/Application Support/Google/Chrome/Profile 2/Application Cache:${HOME}/Library/Application Support/Google/Chrome/Profile 2/Service Worker/CacheStorage" \
-f "${HOME}/Library/Application Support/Google/Chrome/Profile 3/Application Cache:${HOME}/Library/Application Support/Google/Chrome/Profile 3/Service Worker/CacheStorage" \
-f "${HOME}/Library/Application Support/Google/Chrome/Profile 4/Application Cache:${HOME}/Library/Application Support/Google/Chrome/Profile 4/Service Worker/CacheStorage" \
-f "${HOME}/Library/Application Support/com.operasoftware.Opera/Application Cache:${HOME}/Library/Application Support/com.operasoftware.Opera/Service Worker/CacheStorage" \
-R "/Volumes/Ramdisk" "${HOME}/Ramdisk"
COMM
function main {

	# Inizializzazione variabili del tool
	lazy_init_tool_vars

	# Parsing input utente
	parse_input "${@}" || return ${?}
	# Validazione input
	validate_input || return ${?}

	# Inizializzazione variabili
	lazy_init_vars

	# Controllo dipendenze
	if [[ "${check_deps_op}" == true ]]; then
		# Controllo se il sistema operativo è MacOSX
		check_os || return ${?}
		# Controllo tools non builtin
		check_tools awk basename chmod chown column cp csrutil diskutil hdiutil ln mkdir mv \
			newfs_apfs open read readlink rsync tee touch rm whoami xmllint || return ${?}
	fi

	# Creazione ramdisk
	if [[ "${create_ramdisk_op}" == true ]]; then
		create_ramdisk "${ramdisk_name}" "${ramdisk_mount_point}" ${ramdisk_size} || return ${?}

		# Creazione links all'interno del ramdisk
		if [[ "${#links[@]}" -gt 0 ]]; then
			# Controllo se il System Integrity Protection è attivo
			if [[ "${check_csr_op}" == true ]]; then
				if get_csr_status; then
					msg 'R' 'ERRORE: Impossibile creare i links: il CSR è attivo'
					return ${EXIT_FAILURE}
				fi
			fi

			check_root || return ${?}
			create_links "${links[@]}" || msg 'R' 'Errore durante la creazione dei links nel ramdisk'
		fi

		# Creazione directory Trash all'interno del ramdisk
		if [[ "${create_trash_op}" == true ]]; then
			create_trash || return ${?}
		fi

		# Creazione link del ramdisk all'interno della directory Download
		if [[ "${create_link_Download_op}" == true ]]; then
			create_link_Download || return ${?}
		fi

		# Restore contenuto permanente ramdisk
		if [[ "${restore_ramdisk_op}" == true ]]; then
			restore_ramdisk || return ${?}
		fi

	# Setup script e file *.plist per la creazione automatica di un ramdisk ad avvio di sistema
	elif [[ "${setup_ramdisk_op}" == true ]]; then
		# Controllo se il System Integrity Protection è attivo
		if [[ "${check_csr_op}" == true ]]; then
			if get_csr_status; then
				msg 'R' "ERRORE: Impossibile imposatare la creazione del ramdisk all'avvio del sistema: il CSR è attivo"
				return ${EXIT_FAILURE}
			fi
		fi

		check_root || return ${?}
		setup_ramdisk || return ${?}

	# Backup contenuto ramdisk
	elif [[ "${backup_ramdisk_op}" == true ]]; then
		backup_ramdisk || return ${?}

	# Rebuilding links in ramdisk
	elif [[ "${rebuild_links_op}" == true ]]; then
		# Controllo se il System Integrity Protection è attivo
		if [[ "${check_csr_op}" == true ]]; then
			if get_csr_status; then
				msg 'R' 'ERRORE: Impossibile ricostruire i links: il CSR è attivo'
				return ${EXIT_FAILURE}
			fi
		fi

		check_root || return ${?}
		rebuild_links || return ${?}

	# Rimozione script e file *.plist per la creazione automatica del ramdisk ad avvio sistema
	elif [[ "${unload_service_op}" == true ]]; then
		# Controllo se il System Integrity Protection è attivo
		if [[ "${check_csr_op}" == true ]]; then
			if get_csr_status; then
				msg 'R' 'ERRORE: Impossibile fare cleanup: il CSR è attivo'
				return ${EXIT_FAILURE}
			fi
		fi

		check_root || return ${?}
		unload_service || return ${?}

	# Restore contenuto permanente ramdisk
	elif [[ "${restore_ramdisk_op}" == true ]]; then
		restore_ramdisk || return ${?}
	fi

	# Verifica salute links simbolici
	if [[ "${link_health_op}" == true ]]; then
		check_links_health || return ${?}
	fi

	return ${EXIT_SUCCESS}

}

main "${@}"
on_exit ${?}
