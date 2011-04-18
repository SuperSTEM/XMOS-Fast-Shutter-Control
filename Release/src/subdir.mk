################################################################################
# Automatically-generated file. Do not edit!
################################################################################

# Add inputs and outputs from these tool invocations to the build variables 
XC_SRCS += \
../src/fbsMT.xc 

OBJS += \
./src/fbsMT.o 


# Each subdirectory must supply rules for building sources it contributes
src/%.o: ../src/%.xc
	@echo 'Building file: $<'
	@echo 'Invoking: XC Compiler'
	xcc -O2 -g -Wall -c -o "$@" "$<" "../XC-1A.xn"
	@echo 'Finished building: $<'
	@echo ' '


