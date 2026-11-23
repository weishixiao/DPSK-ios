# Theos project for the privileged half of the workbench.
#
# It builds one launchd daemon, `dpsk-agentd`, and installs it with the launchd
# job that registers its Mach service. Nothing here is an app: the daemon lives
# outside the sandbox so `task_for_pid` and `mach_vm_read` work at all, which is
# exactly what an app in the RootHide environment cannot do.
#
# Build with the Theos on the device (or a Mac with the iOS SDK):
#   cd agent/service && make package
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = dpsk-agentd
dpsk-agentd_FILES = agentd.mm DPSKAgentSafety.mm DPSKAgentLog.mm DPSKAgentProbe.mm
dpsk-agentd_FRAMEWORKS = Foundation
dpsk-agentd_PRIVATE_FRAMEWORKS =
dpsk-agentd_INSTALL_PATH = /usr/libexec
dpsk-agentd_CFLAGS = -fobjc-arc -Wall -Werror=return-type
# The entitlements are the point: `platform-application` is what lets the daemon
# hold a Mach service from launchd, and `task-for-pid-allow` is what lets it look
# at a process it did not start. Neither is available to an app.
dpsk-agentd_CODESIGN_FLAGS = -Sagentd.entitlements

include $(THEOS_MAKE_PATH)/tool.mk
