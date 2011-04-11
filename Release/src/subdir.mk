################################################################################
# Automatically-generated file. Do not edit!
################################################################################

# Add inputs and outputs from these tool invocations to the build variables 
XC_SRCS += \
../src/fbsMT.xc 

OBJS += \
./src/fbsMT.o 

XC_DEPS += \
./src/fbsMT.d 


# Each subdirectory must supply rules for building sources it contributes
src/%.o: ../src/%.xc
	@echo 'Building file: $<'
	@echo 'Invoking: XC Compiler'
	xcc -O2 -g -Wall -c -MMD -MP -MF"$(@:%.o=%.d)" -MT"$(@:%.o=%.d) $@ " -o $@ "$<" "../XC-1A.xn"
	@echo 'Finished building: $<'
	@echo ' '


