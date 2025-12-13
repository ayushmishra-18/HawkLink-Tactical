HawkLink Tactical System

A dual-app tactical situational awareness system built with Flutter.

Structure

This repository contains two distinct applications:

Commander Console (Desktop):

Windows/Linux/Mac support.

TCP Server for managing units.

3D Satellite Map with tactical plotting.

Located in: /commander_console

Soldier Uplink (Mobile):

Android/iOS support.

GPS Tracking & SOS Beacon.

Secure TCP Uplink to Commander.

Located in: /soldier_app

Getting Started

Prerequisites

Flutter SDK

Visual Studio (for Windows desktop build)

Android Studio (for Mobile build)

Running the Commander Console

cd commander_console
flutter pub get
flutter run -d windows


Running the Soldier App

cd soldier_app
flutter pub get
flutter run -d android
