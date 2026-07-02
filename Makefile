OBS_PROJECT := EA4
OBS_PACKAGE := ea-webapp
DISABLE_BUILD := repository=CentOS_7 repository=xUbuntu_20.04 repository=xUbuntu_22.04
include $(EATOOLS_BUILD_DIR)obs.mk
