# **🦅 HawkLink Tactical System**



**HawkLink Tactical System** is a **dual-application tactical situational awareness platform** built with **Flutter**, designed for secure command-to-unit coordination in disconnected or low-infrastructure environments.



## **📡 System Overview**



This repository contains two independent yet interconnected applications:



##### 🖥️ **Commander Console (Desktop)**



* Cross-platform support: **Windows / Linux / macOS**



* Acts as a **TCP Server** for managing connected units



* **3D Satellite Map** with tactical plotting \& unit visualization



* Designed for command-level decision making



📁 Location: commander\_console/



##### 📱 **Soldier Uplink (Mobile)**



* Cross-platform support: **Android / iOS**



* Real-time **GPS tracking**



* **SOS / Emergency Beacon**



* **Secure TCP uplink** to Commander Console



* Built for field deployment and low-bandwidth usage



📁 Location: soldier\_app/



### 

### 📸 System Screenshot



#### 🖥️ Commander Console View(Desktop)



!\[Commander Console Screenshot](assets/screenshots/commander/commander\_console.png)









#### 📱 Soldiers Uplink View(Mobile)

!\[Soldier Uplink Screenshot](assets/screenshots/soldier/soldier\_1.jpg)



!\[Soldier Uplink Screenshot](assets/screenshots/soldier/soldier\_2.jpg)







##### **🚀** **Getting Started**



###### **🔧 Prerequisites**



###### **Ensure the following tools are installed:**



* Flutter SDK



* Visual Studio (required for Windows desktop builds)



* Android Studio (required for mobile builds)



###### **▶️ Running the Commander Console**



```

cd commander\_console

flutter pub get

flutter run -d windows

```





💡 Replace windows with linux or macos depending on your platform.



###### **▶️** **Running the Soldier App**



```

cd soldier\_app

flutter pub get

flutter run -d android

```





📱 Ensure an Android emulator or physical device is connected.



#### **🛡️ Project Focus**



* Offline-first communication



* Secure TCP-based data exchange



* Tactical visualization \& command acknowledgment



* Designed for defense, emergency response, and disaster operations
