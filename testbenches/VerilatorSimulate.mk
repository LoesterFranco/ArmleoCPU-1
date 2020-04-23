# inputs $(top) $(files), $(cpp_files), $(includepaths)
includepaths+=../ ../../src/includes/

includepathsI=$(addprefix -I,$(includepaths))

VERILATOR = verilator
VERILATOR_COVERAGE = verilator_coverage


VERILATOR_FLAGS = 
# VERILATOR_FLAGS += -Wall
VERILATOR_FLAGS += -cc --exe -Os -x-assign 0 --trace --coverage $(includepathsI) --top-module $(top)

VERILATOR_INPUT = $(files) $(cpp_files)

default: run

build:
	@echo
	@echo "Running verilator"
	$(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_INPUT) 2>&1 | tee verilator.log

	@echo
	@echo "Running verilated makefiles"
	cd obj_dir && $(MAKE) -j 4 -f V$(top).mk
	@echo

run: build
	@echo "Running verilated executable"
	@rm -rf logs
	@mkdir -p logs
	obj_dir/V$(top) +trace

	@echo
	@echo "Running coverage"
	@rm -rf logs/annotated
	$(VERILATOR_COVERAGE) --annotate logs/annotated logs/coverage.dat

	@echo
	@echo "Complete"