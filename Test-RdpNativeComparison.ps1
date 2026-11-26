# Compare the same isolated endpoint through the inbox Windows client. Temporary
# credentials are scoped to this logon session and to the fixture's exact hostname.
function Test-RdpNativeComparison([string] $Endpoint, [string] $User, [string] $Password) {
    if ($env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $Endpoint -ne 'workspace-rdp-fixture.test' -or
        $User -notin @('RW030Alpha','RW030Beta')) { throw 'This comparison is restricted to fixture accounts.' }
    Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class FixtureCredential {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential {
        public uint Flags, Type;
        public string TargetName, Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias, UserName;
    }
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool CredWrite(ref Credential credential, uint flags);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool CredDelete(string target, uint type, uint flags);
    public static void Set(string target, string user, string password) {
        var c = new Credential {
            Type=1, TargetName=target, UserName=user, Persist=1,
            CredentialBlob=Marshal.StringToCoTaskMemUni(password),
            CredentialBlobSize=(uint)(password.Length * 2)
        };
        try {
            if (!CredWrite(ref c,0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        } finally { Marshal.ZeroFreeCoTaskMemUnicode(c.CredentialBlob); }
    }
    public static void Clear(string target) { CredDelete(target,1,0); }
}
'@
    $key = 'TERMSRV/' + $Endpoint
    $native = $null
    try {
        [FixtureCredential]::Set($key, ($env:COMPUTERNAME + '\' + $User), $Password)
        $native = Start-Process -FilePath (Join-Path $env:windir 'System32\mstsc.exe') -ArgumentList ("/v:" + $Endpoint) -PassThru
        $deadline = [DateTime]::UtcNow.AddSeconds(18)
        do {
            Start-Sleep -Milliseconds 600
            $users = (& quser.exe) -join [Environment]::NewLine
            if ($users -match ('(?im)^\s*>?\s*' + $User + '\s+.*\bActive\b')) {
                Write-Host 'Reference mstsc completed Windows logon on this same endpoint.'
                return
            }
        } while ([DateTime]::UtcNow -lt $deadline)
        Write-Host 'Reference mstsc also did not complete unattended logon on this endpoint.'
        foreach ($process in (Get-Process -Name mstsc,CredentialUIBroker -ErrorAction SilentlyContinue)) {
            Write-Host ("Reference UI: " + $process.ProcessName + " / " + $process.MainWindowTitle)
        }
    } finally {
        if ($native -and !$native.HasExited) { Stop-Process -Id $native.Id -Force }
        [FixtureCredential]::Clear($key)
    }
}
