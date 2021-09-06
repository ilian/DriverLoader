#include <stdio.h>
#include <windows.h>
#include <inttypes.h>

BOOL FileExists(LPCTSTR szPath)
{
    DWORD dwAttrib = GetFileAttributes(szPath);

    return (dwAttrib != INVALID_FILE_ATTRIBUTES &&
            !(dwAttrib & FILE_ATTRIBUTE_DIRECTORY));
}

int main(int argc, char *argv[]) {
    int err = 0;
    if (argc < 2) {
        fprintf(stderr, "Usage: %s DRIVER_PATH [SERVICE_NAME]\n", argv[0]);
        return 1;
    }

    char *driver_path = argv[1];
    char *service_name = argc >= 3 ? argv[2] : driver_path;
    char *display_name = service_name;

    if (!FileExists(driver_path)) {
        fprintf(stderr, "Driver does not exist at path %s\n", driver_path);
        return 1;
    }

    SC_HANDLE hSCM = OpenSCManager(NULL, NULL, SC_MANAGER_CREATE_SERVICE);
    if (!hSCM || hSCM == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "Failed to open handle to service control manager\n");
        return 1;
    }

    SC_HANDLE hService = CreateService(
            hSCM,
            service_name,
            display_name,
            SERVICE_ALL_ACCESS,
            SERVICE_KERNEL_DRIVER,
            SERVICE_DEMAND_START,
            SERVICE_ERROR_IGNORE,
            driver_path,
            NULL, NULL, NULL, NULL, NULL
            );

    if (!hService || hService == INVALID_HANDLE_VALUE) {
        DWORD eCreateService = GetLastError();
        if (eCreateService == ERROR_SERVICE_EXISTS) {
            fprintf(stderr, "Service already exists. Opening handle to existing service...\n");
            hService = OpenService(hSCM, service_name, SERVICE_ALL_ACCESS);
            if (!hService || hService == INVALID_HANDLE_VALUE) {
                fprintf(stderr, "Failed to open existing service");
                err = 1;
                goto clean_scm;
            }
        } else {
            fprintf(stderr, "Failed to create service for driver with path %s (%#lx)\n", driver_path, eCreateService);
            err = 1;
            goto clean_scm;
        }
    }

    if (!StartService(hService, 0, NULL)) {
        fprintf(stderr, "Failed to start service for driver with path %s (%#lx)\n", driver_path, GetLastError());
        err = 1;
        goto clean_service;
    }

    printf("Driver started. Press any key to stop the driver...\n");
    getchar();

clean_service:
    DeleteService(hService);
clean_scm:
    CloseServiceHandle(hSCM);
    return err;
}
