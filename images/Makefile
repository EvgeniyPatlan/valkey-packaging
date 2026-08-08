SHELL := /bin/bash
PACKER ?= packer
VARIANT ?= slim

.PHONY: lint unit container build clean

lint:
	shellcheck files/firstboot/valkey-firstboot.sh test/smoke/smoke.sh test/container/run.sh
	$(PACKER) fmt -check -diff packer/
	ansible-lint ansible/

unit:
	bats test/unit/

container:
	test/container/run.sh $(VARIANT)

build:
	$(PACKER) build -var-file=packer/release.pkvars.hcl packer/

clean:
	rm -rf .packer_cache
