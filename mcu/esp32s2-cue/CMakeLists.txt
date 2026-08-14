# cue on ESP32-S2 (Adafruit ESP32-S2 Feather TFT) — ESP-IDF project.
# Build: . $IDF_PATH/export.sh && idf.py -C mcu/esp32s2-cue set-target esp32s2 build
cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(esp32s2_cue)
