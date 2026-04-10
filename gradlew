#!/usr/bin/env sh
APP_HOME=$(dirname "$(readlink -f "$0")")
exec java -jar "$APP_HOME/gradle/wrapper/gradle-wrapper.jar" \
  -classpath "$APP_HOME/gradle/wrapper/gradle-wrapper.jar" \
  org.gradle.wrapper.GradleWrapperMain "$@"
