# Código C# del centinela. Va como texto legible para que cualquiera pueda revisar qué se compila
# con Add-Type. Está escrito en C# 5, que es lo que compila PowerShell 5.1.
#
# Por qué en C# y no en PowerShell: un BadUSB empieza a teclear en cuanto Windows instala el
# teclado, así que el bloqueo tiene que ocurrir dentro del mismo procedimiento de ventana que
# recibe el aviso, sin volver a PowerShell ni sondear con WMI.

function Get-AduanaCodigoCentinela {
    return @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

public static class AduanaCentinela
{
    // Interfaz de dispositivo de los teclados (GUID_DEVINTERFACE_KEYBOARD).
    static readonly Guid InterfazTeclado = new Guid("884b96c3-56ef-11d1-bc8c-00a0c91405dd");
    static readonly IntPtr HWND_MESSAGE = new IntPtr(-3);
    const int WM_DEVICECHANGE = 0x0219;
    const int WM_TIMER = 0x0113;
    const int DBT_DEVICEARRIVAL = 0x8000;
    const int DBT_DEVTYP_DEVICEINTERFACE = 5;
    const int DEVICE_NOTIFY_WINDOW_HANDLE = 0;
    // Desplazamiento del nombre en DEV_BROADCAST_DEVICEINTERFACE: tres DWORD y un GUID.
    const int DESPLAZAMIENTO_NOMBRE = 28;

    [StructLayout(LayoutKind.Sequential)]
    struct DEV_BROADCAST_DEVICEINTERFACE
    {
        public int dbcc_size;
        public int dbcc_devicetype;
        public int dbcc_reserved;
        public Guid dbcc_classguid;
        public short dbcc_name;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEX
    {
        public int cbSize;
        public int style;
        public ProcedimientoVentana lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MSG
    {
        public IntPtr hwnd;
        public int message;
        public IntPtr wParam;
        public IntPtr lParam;
        public int time;
        public int ptX;
        public int ptY;
    }

    delegate IntPtr ProcedimientoVentana(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern ushort RegisterClassEx(ref WNDCLASSEX wc);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateWindowEx(int exStyle, string className, string windowName, int style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")]
    static extern bool DestroyWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    static extern IntPtr DefWindowProc(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr RegisterDeviceNotification(IntPtr recipient, IntPtr filter, int flags);
    [DllImport("user32.dll")]
    static extern bool UnregisterDeviceNotification(IntPtr handle);
    [DllImport("user32.dll")]
    static extern int GetMessage(out MSG msg, IntPtr hWnd, int min, int max);
    [DllImport("user32.dll")]
    static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")]
    static extern IntPtr DispatchMessage(ref MSG msg);
    [DllImport("user32.dll")]
    static extern void PostQuitMessage(int code);
    [DllImport("user32.dll")]
    static extern IntPtr SetTimer(IntPtr hWnd, IntPtr id, uint milisegundos, IntPtr funcion);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool LockWorkStation();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandle(string nombre);

    // Referencia estática al delegado para que el recolector de basura no lo libere mientras
    // Windows todavía lo llama.
    static ProcedimientoVentana procedimiento;
    static HashSet<string> conocidos;
    static string disparador;

    public static string IdTeclado(string ruta)
    {
        if (ruta == null) return null;
        Match m = Regex.Match(ruta, "VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})");
        if (!m.Success) return null;
        return "VID_" + m.Groups[1].Value.ToUpperInvariant() + "&PID_" + m.Groups[2].Value.ToUpperInvariant();
    }

    static IntPtr Procesar(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_DEVICECHANGE && wParam.ToInt64() == DBT_DEVICEARRIVAL && lParam != IntPtr.Zero)
        {
            int tipo = Marshal.ReadInt32(lParam, 4);
            if (tipo == DBT_DEVTYP_DEVICEINTERFACE)
            {
                string ruta = Marshal.PtrToStringUni(new IntPtr(lParam.ToInt64() + DESPLAZAMIENTO_NOMBRE));
                string id = IdTeclado(ruta);
                // Un teclado sin VID y PID reconocibles también se trata como desconocido.
                if (id == null || !conocidos.Contains(id))
                {
                    // Primero se bloquea y después se hace todo lo demás.
                    LockWorkStation();
                    disparador = ruta ?? "(sin nombre)";
                    PostQuitMessage(0);
                }
            }
        }
        else if (msg == WM_TIMER)
        {
            PostQuitMessage(0);
        }
        return DefWindowProc(hWnd, msg, wParam, lParam);
    }

    // Vigila durante los segundos indicados. Devuelve null si no apareció ningún teclado
    // desconocido, o la ruta del dispositivo que disparó el bloqueo.
    public static string Vigilar(int segundos, string[] teclados)
    {
        conocidos = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (teclados != null)
        {
            foreach (string t in teclados) { conocidos.Add(t); }
        }
        disparador = null;
        procedimiento = new ProcedimientoVentana(Procesar);
        IntPtr instancia = GetModuleHandle(null);
        string clase = "AduanaCentinela" + Guid.NewGuid().ToString("N");

        WNDCLASSEX wc = new WNDCLASSEX();
        wc.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX));
        wc.lpfnWndProc = procedimiento;
        wc.hInstance = instancia;
        wc.lpszClassName = clase;
        if (RegisterClassEx(ref wc) == 0)
        {
            throw new InvalidOperationException("No se pudo registrar la clase de ventana del centinela.");
        }
        IntPtr ventana = CreateWindowEx(0, clase, "Aduana centinela", 0, 0, 0, 0, 0, HWND_MESSAGE, IntPtr.Zero, instancia, IntPtr.Zero);
        if (ventana == IntPtr.Zero)
        {
            throw new InvalidOperationException("No se pudo crear la ventana del centinela.");
        }

        DEV_BROADCAST_DEVICEINTERFACE filtro = new DEV_BROADCAST_DEVICEINTERFACE();
        filtro.dbcc_size = Marshal.SizeOf(typeof(DEV_BROADCAST_DEVICEINTERFACE));
        filtro.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
        filtro.dbcc_classguid = InterfazTeclado;
        IntPtr memoria = Marshal.AllocHGlobal(filtro.dbcc_size);
        IntPtr registro = IntPtr.Zero;
        try
        {
            Marshal.StructureToPtr(filtro, memoria, false);
            registro = RegisterDeviceNotification(ventana, memoria, DEVICE_NOTIFY_WINDOW_HANDLE);
            if (registro == IntPtr.Zero)
            {
                throw new InvalidOperationException("Windows no aceptó el aviso de teclados nuevos.");
            }
            SetTimer(ventana, new IntPtr(1), (uint)(segundos * 1000), IntPtr.Zero);
            MSG m;
            while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0)
            {
                TranslateMessage(ref m);
                DispatchMessage(ref m);
            }
        }
        finally
        {
            if (registro != IntPtr.Zero) { UnregisterDeviceNotification(registro); }
            DestroyWindow(ventana);
            Marshal.FreeHGlobal(memoria);
        }
        return disparador;
    }
}
'@
}

# Configuración de Windows Sandbox: sin red ni portapapeles ni dispositivos, y la ruta montada en
# solo lectura en el escritorio de la máquina desechable.
function New-AduanaConfiguracionSandbox {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    $origen = [Security.SecurityElement]::Escape($Ruta)
    return @"
<Configuration>
  <VGpu>Disable</VGpu>
  <Networking>Disable</Networking>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <PrinterRedirection>Disable</PrinterRedirection>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <ProtectedClient>Enable</ProtectedClient>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$origen</HostFolder>
      <SandboxFolder>C:\Users\WDAGUtilityAccount\Desktop\Pendrive</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
  </MappedFolders>
</Configuration>
"@
}
