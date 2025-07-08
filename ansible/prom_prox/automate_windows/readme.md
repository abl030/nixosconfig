# Windows 11 Custom ISO Builder for Proxmox

This project contains a set of scripts to create a customized Windows 11 installation ISO. The primary purpose is to inject the necessary VirtIO drivers for Storage (SCSI) and Network (NetKVM) so that the Windows installer can detect the virtual hardware in a Proxmox environment, enabling a fully automated installation.

## Requirements

Before you begin, you must download and install the following:

1.  **Windows 11 ISO**: The official disk image from the [Microsoft Software Download page](https://www.microsoft.com/software-download/windows11).
2.  **VirtIO Drivers ISO**: The latest **stable** VirtIO drivers for Windows.
    -   [Fedora Project - Stable virtio-win ISO](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/)
3.  **Windows ADK**: The Windows Assessment and Deployment Kit. You only need to install the **"Deployment Tools"** feature, which provides the `DISM` and `oscdimg` command-line utilities.
    -   [Download the Windows ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) (Ensure you get the version for Windows 11).

> ### **IMPORTANT: Use Signed Drivers Only!**
> Windows 11 has strict driver signature requirements. The official VirtIO drivers from the Fedora project are properly signed by Red Hat and will work without issue. Do not use old or unsigned drivers, as the injection will fail or the installer will refuse to load them.

## How to Use

Follow these steps in order.

### Step 1: Prepare the Folders and Files

1.  Run the `1-Prepare-Folders.bat` script. This will create the `C:\ISO_BUILD`, `C:\DRIVERS`, and `C:\MOUNT` directories.
2.  Follow the manual instructions provided by the script:
    -   Mount the **Windows 11 ISO** and copy all of its contents into `C:\ISO_BUILD`.
    -   Mount the **VirtIO Drivers ISO** and copy the `viostor` and `NetKVM` driver files for `w11\amd64` into `C:\DRIVERS` as instructed.
    -   (Optional) If you have an `autounattend.xml` file for automated installation, place it in the root of the `C:\ISO_BUILD` folder.

### Step 2: Build the ISO

1.  **Temporarily Disable Your Antivirus!** This is a critical step. Real-time protection (including Windows Defender) will lock the `.wim` files during the `DISM` commit phase and cause the script to hang indefinitely.
2.  Open the **"Deployment and Imaging Tools Environment"** from the Start Menu **as an Administrator**.
3.  Run the main build script:
    ```cmd
    2-Inject-Drivers-and-Build-ISO.bat
    ```
4.  **Be patient.** The script will process three different images and then build the final ISO. The step for `install.wim` will take the most time.
5.  Once the script completes, you will find your new ISO at `C:\Windows11-Proxmox-Ready.iso`.
6.  **IMMEDIATELY RE-ENABLE YOUR ANTIVIRUS SOFTWARE.**

## Customization

The `2-Inject-Drivers-and-Build-ISO.bat` script has a configuration section at the top. You can edit these variables if your needs change:

-   `FINAL_ISO_NAME`: Change the output path and filename of the final ISO.
-   `INSTALL_WIM_INDEX`: If you are using a different edition of Windows (e.g., Home instead of Pro), you will need to find its correct index number. You can do this by running `dism /get-imageinfo /imagefile:C:\ISO_BUILD\sources\install.wim`.
