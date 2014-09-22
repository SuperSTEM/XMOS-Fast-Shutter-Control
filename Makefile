# The TARGET variable determines what target system the application is
# compiled for. It either refers to an XN file in the source directories
# or a valid argument for the --target option when compiling
TARGET = XC-1A

# The APP_NAME variable determines the name of the final .xe file. It should
# not include the .xe postfix. If left blank the name will default to
# the project name
APP_NAME = FBS_xTime

# The USED_MODULES variable lists other module used by the application.
USED_MODULES = module_random

# The flags passed to xcc when building the application
# You can also set the following to override flags for a particular language:
# XCC_XC_FLAGS, XCC_C_FLAGS, XCC_ASM_FLAGS, XCC_CPP_FLAGS
# If the variable XCC_MAP_FLAGS is set it overrides the flags passed to
# xcc for the final link (mapping) stage.
XCC_FLAGS_Debug = 
XCC_XC_FLAGS_Debug = -g -O0 -Wall
XCC_C_FLAGS_Debug = -g -O0 -Wall
XCC_CPP_FLAGS_Debug = -g3 -O0 -Wall
XCC_MAP_FLAGS_Debug = -fno-error=timing-syntax
XCC_ASM_FLAGS_Debug = -g
XCC_FLAGS_Release = 
XCC_XC_FLAGS_Release = -g -O2 -Wall
XCC_C_FLAGS_Release = -g -O2 -Wall
XCC_CPP_FLAGS_Release = -g3 -O3 -Wall
XCC_MAP_FLAGS_Release = -fno-error=timing-syntax
XCC_ASM_FLAGS_Release = -g
XCC_FLAGS_1.1_debug = 
XCC_XC_FLAGS_1.1_debug = -g -O0 -Wall
XCC_C_FLAGS_1.1_debug = -g -O0 -Wall
XCC_CPP_FLAGS_1.1_debug = -g3 -O0 -Wall
XCC_MAP_FLAGS_1.1_debug = -fno-error=timing-syntax
XCC_ASM_FLAGS_1.1_debug = -g
XCC_FLAGS_1.1_release = 
XCC_XC_FLAGS_1.1_release = -g -O2 -Wall
XCC_C_FLAGS_1.1_release = -g -O2 -Wall
XCC_CPP_FLAGS_1.1_release = -g3 -O3 -Wall
XCC_MAP_FLAGS_1.1_release = -fno-error=timing-syntax
XCC_ASM_FLAGS_1.1_release = -g
XCC_FLAGS_1.2_release = 
XCC_XC_FLAGS_1.2_release = -g -O2 -Wall
XCC_C_FLAGS_1.2_release = -g -O2 -Wall
XCC_CPP_FLAGS_1.2_release = -g3 -O3 -Wall
XCC_MAP_FLAGS_1.2_release = -fno-error=timing-syntax
XCC_ASM_FLAGS_1.2_release = -g

# The XCORE_ARM_PROJECT variable, if set to 1, configures this
# project to create both xCORE and ARM binaries.
XCORE_ARM_PROJECT = 0

# The VERBOSE variable, if set to 1, enables verbose output from the make system.
VERBOSE = 0

XMOS_MAKE_PATH ?= ../..
-include $(XMOS_MAKE_PATH)/xcommon/module_xcommon/build/Makefile.common
