export SHELL=/bin/bash

ifeq ($(TARGET),)
  $(error TARGET not set)
endif

ENGINE_NAME ?= jerry

CROSS_COMPILE ?= arm-none-eabi-
CC  = g++
LD  = ld
OBJDUMP = objdump
OBJCOPY = objcopy
SIZE = size
STRIP = strip

MAIN_MODULE_SRC = src/main.c

LNK_SCRIPT_STM32F3 = third-party/stm32f3.ld
LNK_SCRIPT_STM32F4 = third-party/stm32f4.ld

# Parsing target
#   '.' -> ' '
TARGET_SPACED := $(subst ., ,$(TARGET))
#   extract target mode part
TARGET_MODE   := $(word 1,$(TARGET_SPACED))
#   extract target system part with modifiers
TARGET_SYSTEM_AND_MODS := $(word 2,$(TARGET_SPACED))
TARGET_SYSTEM_AND_MODS_SPACED := $(subst -, ,$(TARGET_SYSTEM_AND_MODS))

#   extract target system part
TARGET_SYSTEM := $(word 1,$(TARGET_SYSTEM_AND_MODS_SPACED))

#   extract modifiers
TARGET_MODS := $(wordlist 2, $(words $(TARGET_SYSTEM_AND_MODS_SPACED)), $(TARGET_SYSTEM_AND_MODS_SPACED))

#   extract optional action part
TARGET_ACTION := $(word 3,$(TARGET_SPACED))

# Target used as dependency of an action (check, flash, etc.)
TARGET_OF_ACTION := $(TARGET_MODE).$(TARGET_SYSTEM_AND_MODS)

# unittests mode -> linux system
ifeq ($(TARGET_MODE),$(TESTS_TARGET))
 TARGET_SYSTEM := linux
 TARGET_SYSTEM_AND_MODS := $(TARGET_SYSTEM)
endif

# target folder name in $(OUT_DIR)
TARGET_DIR=$(OUT_DIR)/$(TARGET_MODE).$(TARGET_SYSTEM_AND_MODS)

#
# Options setup
#

# Is MCU target?
ifeq ($(filter-out $(TARGET_MCU_SYSTEMS),$(TARGET_SYSTEM)),)
	OPTION_MCU = enable
else
	OPTION_MCU = disable
endif

# Override debug symbols settings
ifeq ($(dbgsyms),1)
  OPTION_OVERRIDE_ENABLE_DBGSYMS := enable
else
  OPTION_OVERRIDE_ENABLE_DBGSYMS := disable
endif

# Override optimization settings
ifeq ($(noopt),1)
  OPTION_OVERRIDE_DISABLE_OPTIMIZE := enable
else
  OPTION_OVERRIDE_DISABLE_OPTIMIZE := disable
endif

# DWARF version
ifeq ($(dwarf4),1)
    OPTION_DWARF4 := enable
else
    OPTION_DWARF4 := disable
endif

# Print TODO, FIXME
ifeq ($(todo),1)
    OPTION_TODO := enable
else
    OPTION_TODO := disable
endif

# Parser error code
PARSER_ERROR_CODE := 255

ifeq ($(fixme),1)
    OPTION_FIXME := enable
else
    OPTION_FIXME := disable
endif

# Compilation command line echoing
ifeq ($(echo),1)
     OPTION_ECHO := enable
else
     OPTION_ECHO := disable
endif

# Turn off pre-compilation static analysis tools
ifeq ($(nostaticcheck),1)
  OPTION_DISABLE_STATIC_ANALYSIS := enable
else
  OPTION_DISABLE_STATIC_ANALYSIS := disable
endif

# -fdiagnostics-color=always
ifeq ($(color),1)
     ifeq ($(OPTION_MCU),enable)
      $(error MCU target doesn\'t support coloring compiler's output)
     endif

     OPTION_COLOR := enable
else
     OPTION_COLOR := disable
endif

# JERRY_NDEBUG, debug symbols
ifeq ($(TARGET_MODE),release)
 OPTION_NDEBUG = enable
 OPTION_DEBUG_SYMS = disable
 OPTION_STRIP = enable
else
 OPTION_NDEBUG = disable
 OPTION_DEBUG_SYMS = enable
 OPTION_STRIP = disable
endif

# Optimizations
ifeq ($(filter-out release $(TESTS_TARGET),$(TARGET_MODE)),)
 OPTION_OPTIMIZE = enable
else
 OPTION_OPTIMIZE = disable
endif

# Applying override options
ifeq ($(OPTION_OVERRIDE_ENABLE_DBGSYMS),enable)
 OPTION_DEBUG_SYMS = enable
 OPTION_STRIP = disable
endif

ifeq ($(OPTION_OVERRIDE_DISABLE_OPTIMIZE),enable)
  OPTION_OPTIMIZE = disable
endif

# CompactProfile mode
ifeq ($(OPTION_MCU),enable)
     OPTION_COMPACT_PROFILE := enable
else
  ifeq ($(filter cp,$(TARGET_MODS)), cp)
       OPTION_COMPACT_PROFILE := enable
  else
       OPTION_COMPACT_PROFILE := disable
  endif
endif

# minimal CompactProfile mode
ifeq ($(filter cp_minimal,$(TARGET_MODS)), cp_minimal)
     OPTION_COMPACT_PROFILE := enable
     OPTION_CP_MINIMAL := enable
else
     OPTION_CP_MINIMAL := disable
endif

ifeq ($(filter sanitize,$(TARGET_MODS)), sanitize)
     OPTION_SANITIZE := enable
else
     OPTION_SANITIZE := disable
endif

ifeq ($(filter valgrind,$(TARGET_MODS)), valgrind)
     OPTION_VALGRIND := enable

     ifeq ($(OPTION_SANITIZE),enable)
      $(error ASAN and Valgrind are mutually exclusive)
     endif
else
     OPTION_VALGRIND := disable
endif

ifeq ($(filter mem_stats,$(TARGET_MODS)), mem_stats)
     OPTION_MEM_STATS := enable
else
     OPTION_MEM_STATS := disable
endif

#
# Target CPU
#
TARGET_CPU = $(strip $(if $(filter linux,$(TARGET_SYSTEM)), x64, \
                     $(if $(filter stm32f3,$(TARGET_SYSTEM)), cortexm4, \
                     $(if $(filter stm32f4,$(TARGET_SYSTEM)), cortexm4, \
                     $(error Do not know target CPU for target system '$(TARGET_SYSTEM)')))))

#
# Flag blocks
#

# Warnings
CFLAGS_WARNINGS ?= -Wall -Wextra -Wpedantic -Wlogical-op -Winline \
                   -Wformat-nonliteral -Winit-self -Wstack-protector \
                   -Wconversion -Wsign-conversion -Wformat-security
CFLAGS_WERROR ?= -Werror
CFLAGS_WFATAL_ERRORS ?= -Wfatal-errors

# Optimizations
CFLAGS_OPTIMIZE ?= -Os -fomit-frame-pointer -flto
CFLAGS_NO_OPTIMIZE ?= -O0
LDFLAGS_OPTIMIZE ?=
LDFLAGS_NO_OPTIMIZE ?=

# Debug symbols
CFLAGS_DEBUG_SYMS ?= -g3

ifeq ($(OPTION_DWARF4),enable)
     CFLAGS_DEBUG_SYMS += -gdwarf-4
else
     CFLAGS_DEBUG_SYMS += -gdwarf-3
endif

# Cortex-M4 MCU
CFLAGS_CORTEXM4 ?= -mlittle-endian -mcpu=cortex-m4 -march=armv7e-m -mthumb \
		   -mfpu=fpv4-sp-d16 -mfloat-abi=hard 


#
# Common
#

CFLAGS_COMMON ?= $(INCLUDES) -std=c++11 -nostdlib -fno-exceptions -fno-rtti
LDFLAGS ?= -lgcc

ifeq ($(OPTION_OPTIMIZE),enable)
 CFLAGS_COMMON += $(CFLAGS_OPTIMIZE)
 LDFLAGS += $(LDFLAGS_OPTIMIZE)
else
 CFLAGS_COMMON += $(CFLAGS_NO_OPTIMIZE)
 LDFLAGS += $(LDFLAGS_NO_OPTIMIZE)
endif

ifeq ($(OPTION_DEBUG_SYMS),enable)
 CFLAGS_COMMON += $(CFLAGS_DEBUG_SYMS)
endif

# CPU-specific common
ifeq ($(TARGET_CPU),cortexm4)
 CFLAGS_COMMON += $(CFLAGS_CORTEXM4)
endif

ifeq ($(OPTION_MCU),enable)
 CC := $(CROSS_COMPILE)$(CC)
 LD := $(CROSS_COMPILE)$(LD)
 OBJDUMP := $(CROSS_COMPILE)$(OBJDUMP)
 OBJCOPY := $(CROSS_COMPILE)$(OBJCOPY)
 SIZE := $(CROSS_COMPILE)$(SIZE)
 STRIP := $(CROSS_COMPILE)$(STRIP)
endif

#
# Jerry part sources, headers, includes, cflags, ldflags
#

GIT_BRANCH=$(shell git symbolic-ref -q HEAD)
GIT_HASH=$(shell git rev-parse HEAD)
BUILD_DATE=$(shell date +'%d/%m/%Y')

CFLAGS_JERRY = $(CFLAGS_WARNINGS) $(CFLAGS_WERROR) $(CFLAGS_WFATAL_ERRORS)
DEFINES_JERRY =

DEFINES_JERRY += -DJERRY_BUILD_DATE="\"$(BUILD_DATE)\"" \
                 -DJERRY_COMMIT_HASH="\"$(GIT_HASH)\"" \
                 -DJERRY_BRANCH_NAME="\"$(GIT_BRANCH)\""

SOURCES_JERRY_C = \
 $(sort \
 $(wildcard src/libruntime/*.c) \
 $(wildcard src/libperipherals/*.c) \
 $(wildcard src/libjsparser/*.c) \
 $(wildcard src/libecmaobjects/*.c) \
 $(wildcard src/libecmaoperations/*.c) \
 $(wildcard src/libecmabuiltins/*.c) \
 $(wildcard src/liballocator/*.c) \
 $(wildcard src/libcoreint/*.c) \
 $(wildcard src/libintstructs/*.c) \
 $(wildcard src/liboptimizer/*.c ) \
 $(wildcard src/libruntime/target/$(TARGET_SYSTEM)/*.c) )

SOURCES_JERRY_H = \
 $(sort \
 $(wildcard src/*.h) \
 $(wildcard src/libruntime/*.h) \
 $(wildcard src/libperipherals/*.h) \
 $(wildcard src/libjsparser/*.h) \
 $(wildcard src/libecmaobjects/*.h) \
 $(wildcard src/libecmaoperations/*.h) \
 $(wildcard src/libecmabuiltins/*.h) \
 $(wildcard src/liballocator/*.h) \
 $(wildcard src/libcoreint/*.h) \
 $(wildcard src/liboptimizer/*.h) \
 $(wildcard src/libintstructs/*.h) \
 $(wildcard src/libruntime/target/$(TARGET_SYSTEM)/*.h) )

SOURCES_JERRY_ASM = \
 $(wildcard src/libruntime/target/$(TARGET_SYSTEM)/*.S)

SOURCES_JERRY = $(SOURCES_JERRY_C) $(SOURCES_JERRY_ASM)

INCLUDES_JERRY = \
 -I src \
 -I src/libruntime \
 -I src/libperipherals \
 -I src/libjsparser \
 -I src/libecmaobjects \
 -I src/libecmaoperations \
 -I src/libecmabuiltins \
 -I src/liballocator \
 -I src/liboptimizer \
 -I src/libcoreint \
 -I src/libintstructs

ifeq ($(OPTION_SANITIZE),enable)
  CFLAGS_COMMON += -fsanitize=address
  LDFLAGS += -lasan
endif

ifeq ($(OPTION_NDEBUG),enable)
 DEFINES_JERRY += -DJERRY_NDEBUG
endif

ifeq ($(OPTION_COMPACT_PROFILE),enable)
  DEFINES_JERRY += -DCONFIG_ECMA_COMPACT_PROFILE
else
  DEFINES_JERRY += -DCONFIG_ECMA_NUMBER_TYPE=CONFIG_ECMA_NUMBER_FLOAT64
endif

ifeq ($(OPTION_CP_MINIMAL),enable)
  DEFINES_JERRY += -DCONFIG_ECMA_COMPACT_PROFILE_DISABLE_NUMBER_BUILTIN \
                   -DCONFIG_ECMA_COMPACT_PROFILE_DISABLE_STRING_BUILTIN \
                   -DCONFIG_ECMA_COMPACT_PROFILE_DISABLE_BOOLEAN_BUILTIN \
                   -DCONFIG_ECMA_COMPACT_PROFILE_DISABLE_ERROR_BUILTINS \
                   -DCONFIG_ECMA_COMPACT_PROFILE_DISABLE_ARRAY_BUILTIN \
                   -DCONFIG_ECMA_COMPACT_PROFILE_DISABLE_MATH_BUILTIN \
                   -DCONFIG_ECMA_COMPACT_PROFILE_DISABLE_DATE_BUILTIN \
                   -DCONFIG_ECMA_COMPACT_PROFILE_DISABLE_JSON_BUILTIN \
                   -DCONFIG_ECMA_COMPACT_PROFILE_DISABLE_REGEXP_BUILTIN \
                   -DCONFIG_ECMA_NUMBER_TYPE=CONFIG_ECMA_NUMBER_FLOAT32
endif

ifeq ($(OPTION_MCU),disable)
 MACHINE_TYPE=$(shell uname -m)
 ifeq ($(MACHINE_TYPE),x86_64)
   DEFINES_JERRY += -D__TARGET_HOST_x64
 else
  ifeq ($(MACHINE_TYPE),armv7l)
    DEFINES_JERRY += -D__TARGET_HOST_ARMv7
  else
    $(error Unsupported machine architecture)
  endif
 endif
 DEFINES_JERRY += -D__TARGET_HOST -DJERRY_SOURCE_BUFFER_SIZE=$$((1024*1024))
 CFLAGS_COMMON += -fno-stack-protector
else
 CFLAGS_COMMON += -ffunction-sections -fdata-sections -nostdlib
 DEFINES_JERRY += -D__TARGET_MCU
 LDFLAGS += -Wl,--gc-sections
endif

ifeq ($(OPTION_MEM_STATS),enable)
  DEFINES_JERRY += -DMEM_STATS
endif

ifeq ($(OPTION_COLOR),enable)
  CFLAGS_COMMON += -fdiagnostics-color=always
endif

ifeq ($(OPTION_TODO),enable)
 DEFINES_JERRY += -DJERRY_PRINT_TODO
endif

ifeq ($(OPTION_FIXME),enable)
 DEFINES_JERRY += -DJERRY_PRINT_FIXME
endif

ifeq ($(OPTION_VALGRIND),enable)
 VALGRIND_CMD := "valgrind --error-exitcode=254 --track-origins=yes"
 VALGRIND_TIMEOUT := 60
else
 VALGRIND_CMD :=
 DEFINES_JERRY += -DJERRY_NVALGRIND
 VALGRIND_TIMEOUT :=
endif

#
# Third-party sources, headers, includes, cflags, ldflags
#

SOURCES_THIRDPARTY =
INCLUDES_THIRDPARTY = -I third-party/valgrind/
CFLAGS_THIRDPARTY =

ifeq ($(TARGET_SYSTEM),stm32f4)
 DEFINES_JERRY += -D__TARGET_MCU_STM32F4
 LDFLAGS += -nostartfiles -T$(LNK_SCRIPT_STM32F4)
 SOURCES_THIRDPARTY += \
 	 	third-party/STM32F4-Discovery_FW_V1.1.0/Libraries/CMSIS/ST/STM32F4xx/Source/Templates/system_stm32f4xx.c \
		third-party/STM32F4-Discovery_FW_V1.1.0/Libraries/CMSIS/ST/STM32F4xx/Source/Templates/gcc_ride7/startup_stm32f4xx.s \
                third-party/STM32F4-Discovery_FW_V1.1.0/Libraries/STM32F4xx_StdPeriph_Driver/src/stm32f4xx_tim.c \
                third-party/STM32F4-Discovery_FW_V1.1.0/Libraries/STM32F4xx_StdPeriph_Driver/src/stm32f4xx_gpio.c \
                third-party/STM32F4-Discovery_FW_V1.1.0/Libraries/STM32F4xx_StdPeriph_Driver/src/stm32f4xx_rcc.c

 INCLUDES_THIRDPARTY += \
 	 	-I third-party/STM32F4-Discovery_FW_V1.1.0/Libraries/CMSIS/ST/STM32F4xx/Include \
 	 	-I third-party/STM32F4-Discovery_FW_V1.1.0/Libraries/STM32F4xx_StdPeriph_Driver/inc \
 	 	-I third-party/STM32F4-Discovery_FW_V1.1.0/Libraries/CMSIS/Include \
 	 	-I third-party/STM32F4-Discovery_FW_V1.1.0/
else
  ifeq ($(TARGET_SYSTEM),stm32f3)
   DEFINES_JERRY += -D__TARGET_MCU_STM32F3
   LDFLAGS += -nostartfiles -T$(LNK_SCRIPT_STM32F3)
   SOURCES_THIRDPARTY += \
 	 	third-party/STM32F3-Discovery_FW_V1.1.0/Libraries/CMSIS/Device/ST/STM32F30x/Source/Templates/system_stm32f30x.c             \
                third-party/STM32F3-Discovery_FW_V1.1.0/Libraries/CMSIS/Device/ST/STM32F30x/Source/Templates/gcc_ride7/startup_stm32f30x.s  \
                third-party/STM32F3-Discovery_FW_V1.1.0/Libraries/STM32F30x_StdPeriph_Driver/src/stm32f30x_tim.c                            \
                third-party/STM32F3-Discovery_FW_V1.1.0/Libraries/STM32F30x_StdPeriph_Driver/src/stm32f30x_gpio.c                           \
                third-party/STM32F3-Discovery_FW_V1.1.0/Libraries/STM32F30x_StdPeriph_Driver/src/stm32f30x_rcc.c

   INCLUDES_THIRDPARTY += \
                -I third-party/STM32F3-Discovery_FW_V1.1.0/Libraries/CMSIS/Device/ST/STM32F30x/Include/ \
                -I third-party/STM32F3-Discovery_FW_V1.1.0/Libraries/STM32F30x_StdPeriph_Driver/inc     \
                -I third-party/STM32F3-Discovery_FW_V1.1.0/Libraries/CMSIS/Include/                     \
                -I third-party/STM32F3-Discovery_FW_V1.1.0
  endif
endif

# Unit tests

SOURCES_UNITTESTS = \
 	 $(sort \
 	 $(patsubst %.c,%,$(notdir \
 	 $(wildcard $(UNITTESTS_SRC_DIR)/*.c))))

.PHONY: all clean check install $(JERRY_TARGETS) $(TESTS_TARGET)

all: clean $(JERRY_TARGETS)

$(JERRY_TARGETS):
	@rm -rf $(TARGET_DIR)
	@mkdir -p $(TARGET_DIR)
	@source_and_headers_list=$$(for file in $(SOURCES_JERRY_C) $(MAIN_MODULE_SRC) $(SOURCES_JERRY_H) ; do echo $$file; done | sort); \
     changed_sources_and_headers_list=`comm -12 \
                                       <(echo "$$source_and_headers_list") \
                                       <(git diff --name-only origin/master | sort)`; \
     cpp_check_file_list=$$(echo "$$changed_sources_and_headers_list" | sort); \
     source_to_grep_for_includes="$$source_and_headers_list"; \
     while [[ "$$source_to_grep_for_includes" != "" ]]; \
     do \
       new_cpp_check_file_list="$$cpp_check_file_list"; \
       source_to_grep_for_includes=$$(comm -23 \
                                      <(echo "$$source_to_grep_for_includes") \
                                      <(echo "$$cpp_check_file_list")); \
       cpp_check_header_file_list=$$(echo "$$cpp_check_file_list" | grep "\.h$$"); \
       for header in $$cpp_check_header_file_list; \
       do \
         header=$$(basename $$header); \
         includers=$$(grep "#include \"$$header\"" $$source_to_grep_for_includes | cut -d ':' -f 1); \
         new_cpp_check_file_list=$$(echo -e "$$new_cpp_check_file_list\n$$includers"); \
       done; \
       new_cpp_check_file_list=$$(echo "$$new_cpp_check_file_list" | sort | uniq); \
       if [[ "$$cpp_check_file_list" == "$$new_cpp_check_file_list" ]]; \
       then \
         break; \
       fi; \
       cpp_check_file_list="$$new_cpp_check_file_list"; \
     done; \
     cpp_check_file_list=$$(echo "$$cpp_check_file_list" | grep -v "\.h$$"); \
	 [[ "$(OPTION_DISABLE_STATIC_ANALYSIS)" == "enable" ]] || [[ "$$cpp_check_file_list" == "" ]] || \
          ./tools/cppcheck.sh -j8 $(DEFINES_JERRY) $$cpp_check_file_list $(INCLUDES_JERRY) $(INCLUDES_THIRDPARTY) \
          --error-exitcode=1 --language=c++ --std=c++11 --enable=all 1>/dev/null || exit $$?; \
	 [[ "$(OPTION_DISABLE_STATIC_ANALYSIS)" == "enable" ]] || [[ "$$changed_sources_and_headers_list" == "" ]] || \
          vera++ -r ./tools/vera++ -p jerry $$changed_sources_and_headers_list \
          -e --no-duplicate 1>$(TARGET_DIR)/vera.log || exit $$?;
	@mkdir -p $(TARGET_DIR)/obj
	@source_index=0; \
	for jerry_src in $(SOURCES_JERRY) $(MAIN_MODULE_SRC); do \
		cmd="$(CC) -c $(DEFINES_JERRY) $(CFLAGS_COMMON) $(CFLAGS_JERRY) $(INCLUDES_JERRY) $(INCLUDES_THIRDPARTY) $$jerry_src \
                     -o $(TARGET_DIR)/obj/$$(basename $$jerry_src).$$source_index.o"; \
                if [ "$(OPTION_ECHO)" = "enable" ]; then echo $$cmd; echo; fi; \
		$$cmd; \
		if [ $$? -ne 0 ]; then echo Failed "'$$cmd'"; exit 1; fi; \
		source_index=$$(($$source_index+1)); \
	done; \
	for thirdparty_src in $(SOURCES_THIRDPARTY); do \
		cmd="$(CC) -c $(CFLAGS_COMMON) $(CFLAGS_THIRDPARTY) $(INCLUDES_THIRDPARTY) $$thirdparty_src \
                     -o $(TARGET_DIR)/obj/$$(basename $$thirdparty_src).$$source_index.o"; \
                if [ "$(OPTION_ECHO)" = "enable" ]; then echo $$cmd; echo; fi; \
		$$cmd; \
		if [ $$? -ne 0 ]; then echo Failed "'$$cmd'"; exit 1; fi; \
		source_index=$$(($$source_index+1)); \
	done; \
	cmd="$(CC) $(CFLAGS_COMMON) $(TARGET_DIR)/obj/* $(LDFLAGS) -o $(TARGET_DIR)/$(ENGINE_NAME)"; \
        if [ "$(OPTION_ECHO)" = "enable" ]; then echo $$cmd; echo; fi; \
	$$cmd; \
	if [ $$? -ne 0 ]; then echo Failed "'$$cmd'"; exit 1; fi;
	@if [ "$(OPTION_STRIP)" = "enable" ]; then $(STRIP) $(TARGET_DIR)/$(ENGINE_NAME) || exit $$?; fi;
	@if [ "$(OPTION_MCU)" = "enable" ]; then $(OBJCOPY) -Obinary $(TARGET_DIR)/$(ENGINE_NAME) $(TARGET_DIR)/$(ENGINE_NAME).bin || exit $$?; fi;
	@rm -rf $(TARGET_DIR)/obj

$(TESTS_TARGET):
	@rm -rf $(TARGET_DIR)
	@mkdir -p $(TARGET_DIR)
	@mkdir -p $(TARGET_DIR)/obj
	@[[ "$(OPTION_DISABLE_STATIC_ANALYSIS)" == "enable" ]] || \
          ./tools/cppcheck.sh -j8 $(DEFINES_JERRY) `find $(UNITTESTS_SRC_DIR) -name *.[c]` $(SOURCES_JERRY_C) $(INCLUDES_JERRY) $(INCLUDES_THIRDPARTY) \
          --error-exitcode=1 --language=c++ --std=c++11 --enable=all 1>/dev/null
	@source_index=0; \
	for jerry_src in $(SOURCES_JERRY); \
        do \
                cmd="$(CC) -c $(DEFINES_JERRY) $(CFLAGS_COMMON) $(CFLAGS_JERRY) \
                $(INCLUDES_JERRY) $(INCLUDES_THIRDPARTY) $$jerry_src -o $(TARGET_DIR)/obj/$$(basename $$jerry_src).$$source_index.o"; \
                if [ "$(OPTION_ECHO)" = "enable" ]; then echo $$cmd; echo; fi; \
                $$cmd & \
                ids[$$source_index]=$$!; \
                cmds[$$source_index]="$$cmd"; \
		source_index=$$(($$source_index+1)); \
        done; \
        for i in `seq 1 $$source_index`; \
        do \
          wait $${ids[$$i]}; \
          status_code=$$?; \
          if [ $$status_code -ne 0 ]; then echo Failed "'"$${cmds[$$i]}"'"; exit 1; fi; \
        done
	@unit_test_index=0; \
        for unit_test in $(SOURCES_UNITTESTS); \
	do \
		cmd="$(CC) $(DEFINES_JERRY) $(CFLAGS_COMMON) $(CFLAGS_JERRY) \
		$(INCLUDES_JERRY) $(INCLUDES_THIRDPARTY) $(TARGET_DIR)/obj/*.o $(UNITTESTS_SRC_DIR)/$$unit_test.c -lc -o $(TARGET_DIR)/$$unit_test"; \
                if [ "$(OPTION_ECHO)" = "enable" ]; then echo $$cmd; echo; fi; \
		$$cmd & \
                ids[$$unit_test_index]=$$!; \
                cmds[$$unit_test_index]="$$cmd"; \
		unit_test_index=$$(($$unit_test_index+1)); \
		if [ $$? -ne 0 ]; then echo Failed "'$$cmd'"; exit 1; fi; \
	done; \
        for i in `seq 1 $$unit_test_index`; \
        do \
          wait $${ids[$$i]}; \
          status_code=$$?; \
          if [ $$status_code -ne 0 ]; then echo Failed "'"$${cmds[$$i]}"'"; exit 1; fi; \
        done
	@ rm -rf $(TARGET_DIR)/obj
	@ VALGRIND=$(VALGRIND_CMD) ./tools/jerry_unittest.sh $(TARGET_DIR) $(TESTS_OPTS)

$(CHECK_TARGETS):
	@ if [ ! -f $(TARGET_DIR)/$(ENGINE_NAME) ]; then echo $(TARGET_OF_ACTION) is not built yet; exit 1; fi;
	@ if [[ ! -d "$(TESTS)" && ! -f "$(TESTS)" ]]; then echo \"$(TESTS)\" is not a directory and not a file; exit 1; fi;
	@ rm -rf $(TARGET_DIR)/check
	@ mkdir -p $(TARGET_DIR)/check
	@ if [ "$(OUTPUT_TO_LOG)" = "enable" ]; \
          then \
            ADD_OPTS="--output-to-log"; \
          fi; \
          VALGRIND=$(VALGRIND_CMD) TIMEOUT=$(VALGRIND_TIMEOUT) ./tools/jerry_test.sh $(TARGET_DIR)/$(ENGINE_NAME) $(TARGET_DIR)/check $(TESTS) $(TESTS_OPTS) $$ADD_OPTS; \
          status_code=$$?; \
          if [ $$status_code -ne 0 ]; \
          then \
            echo $(TARGET) failed; \
            if [ "$(OUTPUT_TO_LOG)" = "enable" ]; \
            then \
              echo See log in $(TARGET_DIR)/check directory for details.; \
            fi; \
            \
            exit $$status_code; \
          fi; \
          if [ -d $(TESTS_DIR)/fail/ ]; \
          then \
            VALGRIND=$(VALGRIND_CMD) TIMEOUT=$(VALGRIND_TIMEOUT) ./tools/jerry_test_fail.sh $(TARGET_DIR)/$(ENGINE_NAME) $(TARGET_DIR)/check $(PARSER_ERROR_CODE) $(TESTS_DIR) $(TESTS_OPTS) $$ADD_OPTS; \
            status_code=$$?; \
            if [ $$status_code -ne 0 ]; \
            then \
              echo $(TARGET) failed; \
              if [ "$(OUTPUT_TO_LOG)" = "enable" ]; \
              then \
                echo See log in $(TARGET_DIR)/check directory for details.; \
              fi; \
              \
              exit $$status_code; \
            fi; \
          fi;


$(FLASH_TARGETS): $(TARGET_OF_ACTION)
	st-flash write $(OUT_DIR)/$(TARGET_OF_ACTION)/jerry.bin 0x08000000 || exit $$?
