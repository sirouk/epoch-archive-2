# https://github.com/0LNetworkCommunity/epoch-archive
# Note: Made for v6.9 > v7.0

SHELL=/usr/bin/env bash

ifndef GIT_ORG
GIT_ORG = sirouk
endif

ifndef GIT_REPO
GIT_REPO = epoch-archive-2
endif

ifndef BIN_PATH
BIN_PATH=~/bin
endif

ifndef SOURCE_PATH
SOURCE_PATH=~/libra-framework
endif

ifndef REPO_PATH
REPO_PATH=~/${GIT_REPO}
endif

ifndef ARCHIVE_PATH
ARCHIVE_PATH=${REPO_PATH}/snapshots
endif

ifndef GENESIS_PATH
GENESIS_PATH=~/.libra/genesis
endif

ifndef DATA_PATH
DATA_PATH=~/.libra/data
endif

ifndef DB_PATH
DB_PATH=${DATA_PATH}/db
endif

ifndef BACKUP_SERVICE_URL
BACKUP_SERVICE_URL=http://localhost
endif

ifndef BACKUP_EPOCH_FREQ
BACKUP_EPOCH_FREQ = 1
endif

ifndef BACKUP_TRANS_FREQ
BACKUP_TRANS_FREQ = 20000
endif


ifndef EPOCH_NOW
EPOCH_NOW := $(shell libra query epoch | jq -r '.epoch' | bc)
endif

ifndef LAST_EPOCH
LAST_EPOCH=$(shell expr ${EPOCH_NOW} - 1)
endif

ifndef NEXT_EPOCH
NEXT_EPOCH = $(shell expr ${EPOCH} + 1)
endif

ifndef DB_VERSION
# sirouk 2023-09-09 - to be replaced with libra query block-height
DB_VERSION := $(shell curl 127.0.0.1:9101/metrics 2> /dev/null | grep "^diem_storage_latest_state_checkpoint_version [0-9]\+" | awk '{print $$2}' | bc)
endif

GIT_API_BASE = https://api.github.com/repos/${GIT_ORG}/${GIT_REPO}
BACKUP_INFO ?= $(shell latest_version=0; first_version=0; \
	contents=$$(curl -s "${GIT_API_BASE}/git/trees/main?recursive=1" | jq -r '.tree[] | select(.path | test("transaction_[0-9]+-.*/transaction.manifest$$")) | .path'); \
	for path in $$contents; do \
		versions=$$(curl -s "${GIT_API_BASE}/contents/$$path" | jq -r '.content' | base64 --decode | gunzip | jq -r '.first_version, .last_version'); \
		fv=$$(echo "$$versions" | head -n 1); \
		cv=$$(echo "$$versions" | tail -n 1); \
		if [ $$cv -gt $$latest_version ]; then \
			first_version=$$fv; \
			latest_version=$$cv; \
		fi; \
	done; \
	echo $$first_version:$$latest_version)

LATEST_BACKUP_FV = $(word 1,$(subst :, ,${BACKUP_INFO}))
LATEST_BACKUP = $(word 2,$(subst :, ,${BACKUP_INFO}))

ifndef NEXT_BACKUP
NEXT_BACKUP = $(shell echo "${LATEST_BACKUP} + ${BACKUP_TRANS_FREQ}" | bc)
endif

ifndef EPOCH
EPOCH = ${EPOCH_NOW}
endif

ifndef VERSION_START
VERSION_START = ${LATEST_BACKUP_FV}
endif

ifndef VERSION
VERSION = ${DB_VERSION}
endif


ifndef RESTORE_EPOCH_WAYPOINT
echo "EPOCH_WAYPOINT: ${EPOCH_WAYPOINT}"
EPOCH_WAYPOINT = $(shell jq -r ".waypoints[0]" ${ARCHIVE_PATH}/${EPOCH}/ep*/epoch_ending.manifest)
endif

ifndef RESTORE_EPOCH_HEIGHT
RESTORE_EPOCH_HEIGHT = $(shell echo ${EPOCH_WAYPOINT} | cut -d ":" -f 1)
endif


check:
	@if test -z ${EPOCH}; then \
		echo "Must provide EPOCH in environment" 1>&2; \
	 	exit 1; \
	fi

	echo bin-path: ${BIN_PATH}
	echo repo-path: ${REPO_PATH}
	echo source-path: ${SOURCE_PATH}
	echo archive-path: ${ARCHIVE_PATH}
	echo data-path: ${DATA_PATH}
	echo target-db: ${DB_PATH}
	echo backup-service-url: ${BACKUP_SERVICE_URL}
	echo backup-epoch-freq: ${BACKUP_EPOCH_FREQ}
	echo backup-trans-freq: ${BACKUP_TRANS_FREQ}
	
	echo epoch-now: ${EPOCH_NOW}
	echo last-epoch: ${LAST_EPOCH}
	echo next-epoch: ${NEXT_EPOCH}
	echo db-version: ${DB_VERSION}
	
	echo latest-backup-fv: ${LATEST_BACKUP_FV}
	echo latest-backup: ${LATEST_BACKUP}
	echo next-backup: ${NEXT_BACKUP}

	echo start-epoch: ${EPOCH}
	echo epoch-version: ${VERSION}
	
	echo restore-epoch-waypoint: ${RESTORE_EPOCH_WAYPOINT}
	echo restore-epoch-height: ${RESTORE_EPOCH_HEIGHT}

wipe-backups:
	cd ${REPO_PATH} && rm -Rf ${ARCHIVE_PATH} && rm -Rf ${REPO_PATH}/genesis && rm -Rf metacache backup.log && git add -A && git commit -m "wipe-backups" && git push

wipe-db:
	sudo rm -rf ${DB_PATH}

prep-archive-path:
	mkdir -p ${ARCHIVE_PATH} && cd ${ARCHIVE_PATH}

bins:
	cd ${SOURCE_PATH} && cargo build -p diem-db-tool --release
	cp -f ${SOURCE_PATH}/target/release/diem-db-tool ${BIN_PATH}/diem-db-tool

sync-repo:
	cd ${REPO_PATH} && git pull && git reset --hard origin/main && git clean -xdf


backup-genesis:
	mkdir -p ${REPO_PATH}/genesis && cp -f ${GENESIS_PATH}/genesis.blob ${REPO_PATH}/genesis/genesis.blob && cp -f ${GENESIS_PATH}/waypoint.txt ${REPO_PATH}/genesis/waypoint.txt

backup-continuous: prep-archive-path backup-genesis
	${BIN_PATH}/diem-db-tool backup continuously --backup-service-address ${BACKUP_SERVICE_URL}:6186 --state-snapshot-interval-epochs ${BACKUP_EPOCH_FREQ} --transaction-batch-size ${BACKUP_TRANS_FREQ} --command-adapter-config ${REPO_PATH}/epoch-archive.yaml

backup-epoch: prep-archive-path
	${BIN_PATH}/diem-db-tool backup oneoff --backup-service-address ${BACKUP_SERVICE_URL}:6186 epoch-ending --start-epoch ${LAST_EPOCH} --end-epoch ${EPOCH_NOW} --target-db-dir ${DB_PATH} --command-adapter-config ${REPO_PATH}/epoch-archive.yaml

backup-snapshot: prep-archive-path
	${BIN_PATH}/diem-db-tool backup oneoff --backup-service-address ${BACKUP_SERVICE_URL}:6186 state-snapshot --target-db-dir ${DB_PATH} --command-adapter-config ${REPO_PATH}/epoch-archive.yaml

backup-transaction: prep-archive-path
	${BIN_PATH}/diem-db-tool backup oneoff --backup-service-address ${BACKUP_SERVICE_URL}:6186 transaction --start-version ${VERSION} --num_transactions ${BACKUP_TRANS_FREQ} --target-db-dir ${DB_PATH}--command-adapter-config ${REPO_PATH}/epoch-archive.yaml

backup-version: backup-epoch backup-snapshot backup-transaction


restore-genesis:
	mkdir -p ${GENESIS_PATH} && cp -f ${REPO_PATH}/genesis/genesis.blob ${GENESIS_PATH}/genesis.blob && cp -f ${REPO_PATH}/genesis/waypoint.txt ${GENESIS_PATH}/waypoint.txt && libra config init

restore-all: sync-repo wipe-db restore-genesis
	cd ${ARCHIVE_PATH} && ${BIN_PATH}/diem-db-tool restore bootstrap-db --target-db-dir ${DB_PATH} --metadata-cache-dir ${REPO_PATH}/metacache --command-adapter-config ${REPO_PATH}/epoch-archive.yaml

restore-latest: sync-repo wipe-db
	cd ${ARCHIVE_PATH} && ${BIN_PATH}/diem-db-tool restore bootstrap-db --ledger-history-start-version ${VERSION_START} --target-version ${VERSION} --target-db-dir ${DB_PATH} --metadata-cache-dir ${REPO_PATH}/metacache --command-adapter-config ${REPO_PATH}/epoch-archive.yaml

restore-not-yet:
	echo "Not now, but soon. You can play, but be careful!"

restore-epoch: restore-not-yet
	cd ${ARCHIVE_PATH} && ${BIN_PATH}/diem-db-tool restore oneoff epoch-ending

restore-transaction: restore-not-yet
	cd ${ARCHIVE_PATH} && ${BIN_PATH}/diem-db-tool restore oneoff transaction

restore-snapshot: restore-not-yet
	echo "Hint: --restore-mode [default, kv_only, tree_only]"
	cd ${ARCHIVE_PATH} && ${BIN_PATH}/diem-db-tool restore oneoff state-snapshot 


git-setup:
	@if [ ! -d ${REPO_PATH} ]; then \
		mkdir -p ${REPO_PATH} && cd ${REPO_PATH} && git clone https://github.com/${GIT_ORG}/${GIT_REPO} .; \
	elif [ -d ${REPO_PATH}/.git ]; then \
		cd ${REPO_PATH}; \
	else \
		echo "Directory exists but is not a git repository. Please handle manually."; \
	fi

git: git-setup
	@cd ${REPO_PATH}; \
	git pull; \
	git add -A; \
	git commit -m "diem-db-tool backup continuously"; \
	git push;

git-sling-recent:
	@cd ${ARCHIVE_PATH}; \
	files=( $$(ls -td -- * | head -n 20) ); \
	for ((i=0; i<$${#files[@]}; i+=20)); do \
		git add "$${files[@]:i:20}"; \
		git commit -m "batch from diem-db-tool backup continuously"; \
		git push; \
	done

git-sling-all:
	@cd ${ARCHIVE_PATH}; \
	while :; do \
		files=$$(git status --porcelain ./* | awk '{gsub(/\/$$/, "", $$2); print $$2}' | xargs -I {} stat --format="%Y %n" {} | sort -n | awk '{print $$2}' | head -n 20); \
		if [ -z "$$files" ]; then \
			break; \
		fi; \
		for file in $$files; do \
			git add "$$file"; \
		done; \
		git commit -m "batch from diem-db-tool backup continuously"; \
		git push; \
	done

start-continuous:
	@cd ${REPO_PATH}; \
	ps aux | grep "diem-db-tool backup continuously" | grep -v "grep" > /dev/null; \
	ps_exit_status=$$?; \
	if [ $$ps_exit_status -ne 0 ]; then \
		echo "Starting Continuous Backup via diem-db-tool..."; \
		cd ${REPO_PATH} && make backup-continuous >> ${REPO_PATH}/backup.log 2>&1 & \
	else \
		echo "diem-db-tool is already running"; \
	fi

stop-continuous:
	@cd ${REPO_PATH}; \
	ps aux | grep "diem-db-tool backup continuously" | grep -v "grep" > /dev/null; \
	ps_exit_status=$$?; \
	if [ $$ps_exit_status -ne 0 ]; then \
		echo "Stopping Continuous Backup via diem-db-tool..."; \
		pkill -f "diem-db-tool backup continuously"; \
	else \
		echo "diem-db-tool is not running"; \
	fi

log-cleanup:
	echo "This is where we will eventually deal with the size of backup.log!"

cron: git start-continuous log-cleanup
