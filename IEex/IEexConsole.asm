GetCommandLine          EQU <GetCommandLineA>

ConsoleParseCmdLine     PROTO :DWORD
ConsoleCmdLineParam     PROTO :DWORD,:DWORD,:DWORD,:DWORD
ConsoleClearScreen      PROTO
ConsoleText             PROTO :DWORD
ConsoleStarted          PROTO
ConsoleAttach           PROTO
ConsoleSendEnterKey     PROTO
ReadFromPipe            PROTO 

.DATA
szBackslash             DB "\",0

hLogFile                DD 0

StartedMode             DD 0

dwBytesRead             DD 0 
TotalBytesAvail         DD 0 
BytesLeftThisMessage    DD 0

szLogFile               DB MAX_PATH DUP (0)

szParameter1Buffer      DB MAX_PATH DUP (0)
CmdLineParameters       DB 512 DUP (0)

PIPEBUFFER              DB 4096 DUP (0) ;4096 DUP (0) - modified to 1 char as console output was cutting off/lagging until it 'filled' buffer size


.DATA?
SecuAttr                SECURITY_ATTRIBUTES <>
hChildStd_OUT_Rd        DD ?
hChildStd_OUT_Wr        DD ?
hChildStd_IN_Rd         DD ?
hChildStd_IN_Wr         DD ?



.CODE

IEEX_ALIGN
;------------------------------------------------------------------------------
; Command-line parser for console applications 
; http://masm32.com/board/index.php?topic=2598.msg27628#msg27628
; Coded by Vortex
; Returns no of parameters parsed and stored in the dwParametersArray
;------------------------------------------------------------------------------
ConsoleParseCmdLine PROC USES EBX EDI ESI dwParametersArray:DWORD

    invoke  GetCommandLine
    lea     edx,[eax-1]
    xor     eax,eax
    mov     esi,dwParametersArray
    lea     edi,[esi+256]
    mov     ch,32
    mov     bl,9

scan:

    inc     edx
    mov     cl,BYTE PTR [edx]
    test    cl,cl
    jz      finish
    cmp     cl,32
    je      scan
    cmp     cl,9
    je      scan
    inc     eax
    mov     DWORD PTR [esi],edi
    add     esi,4

restart:

    mov     cl,BYTE PTR [edx]
    test    cl,cl
    jne     @f
    mov     BYTE PTR [edi],cl
    ret
@@:
    cmp     cl,ch
    je      end_of_line
    cmp     cl,bl
    je      end_of_line
    cmp     cl,34
    jne     @f
    xor     ch,32
    xor     bl,9
    jmp     next_char
@@:	
    mov     BYTE PTR [edi],cl
    inc     edi

next_char:

    inc     edx
    jmp     restart

end_of_line:

    mov     BYTE PTR [edi],0
    inc     edi
    jmp     scan	

finish:

    ret

ConsoleParseCmdLine ENDP

IEEX_ALIGN
;------------------------------------------------------------------------------
; ConsoleCmdLineParam by fearless - fetch parameter by index from cmd line that 
; was parsed via ConsoleParseCmdLine and stored in an array buffer
; 
; Returns -1 if dwParametersArray is empty
; Returns 0 if parameter required is invalid
; Returns > 0 if parameter was fetched, on return lpszReturnedParameter will 
;             contain the string value of the parameter and eax contains the 
;             length of the parameter's string.
;------------------------------------------------------------------------------
ConsoleCmdLineParam PROC USES EBX ESI dwParametersArray:DWORD, dwParameterToFetch:DWORD, dwTotalParameters:DWORD, lpszReturnedParameter:DWORD
    .IF dwParametersArray == 0
        mov eax, -1
        ret
    .ENDIF
    
    mov eax, dwParameterToFetch
    .IF eax > dwTotalParameters ; for safety we require total params so we dont go over and crash
        mov ebx, [lpszReturnedParameter]
        mov byte ptr [ebx], 0h
        mov eax, 0
        ret
    .ENDIF
    
    mov esi, dwParametersArray		
    mov ebx, 4
    mul ebx ; eax contains the no of parameter we want offset for
    add esi, eax ; Now at offset for parameters string

    .IF lpszReturnedParameter != NULL
        Invoke lstrcpyn, lpszReturnedParameter, DWORD PTR [esi], MAX_PATH
        Invoke lstrlen, lpszReturnedParameter ; Get length of parameter. >0 = success
    .ELSE
        mov eax, 0
    .ENDIF
    ret
ConsoleCmdLineParam endp

IEEX_ALIGN
;------------------------------------------------------------------------------
; ConsoleText
;------------------------------------------------------------------------------
ConsoleText PROC lpszConText:DWORD
    LOCAL dwBytesWritten:DWORD
    LOCAL dwBytesToWrite:DWORD

    .IF hConOutput != 0 && lpszConText != 0
        Invoke lstrlen, lpszConText
        mov dwBytesToWrite, eax
        Invoke WriteFile, hConOutput, lpszConText, dwBytesToWrite, Addr dwBytesWritten, NULL
        mov eax, dwBytesWritten
    .ELSE
        xor eax, eax
    .ENDIF
    ret
ConsoleText ENDP

IEEX_ALIGN
;------------------------------------------------------------------------------
; ClearConsoleScreen 
;------------------------------------------------------------------------------
ConsoleClearScreen PROC USES EBX
    LOCAL noc:DWORD
    LOCAL cnt:DWORD
    LOCAL sbi:CONSOLE_SCREEN_BUFFER_INFO
    .IF hConOutput != 0
        Invoke GetConsoleScreenBufferInfo, hConOutput, Addr sbi
        mov eax, sbi.dwSize ; 2 word values returned for screen size
    
        ; extract the 2 values and multiply them together
        mov ebx, eax
        shr eax, 16
        mul bx
        mov cnt, eax
    
        Invoke FillConsoleOutputCharacter, hConOutput, 32, cnt, NULL, Addr noc
        movzx ebx, sbi.wAttributes
        Invoke FillConsoleOutputAttribute, hConOutput, ebx, cnt, NULL, Addr noc
        Invoke SetConsoleCursorPosition, hConOutput, NULL
    .ENDIF
    ret
ConsoleClearScreen ENDP

IEEX_ALIGN
;------------------------------------------------------------------------------
; ConsoleStarted - For GUI Apps - Return TRUE if started from console or FALSE 
; if started via GUI (explorer) 
;------------------------------------------------------------------------------
ConsoleStarted PROC
    LOCAL pidbuffer[8]:DWORD
    Invoke GetConsoleProcessList, Addr pidbuffer, 4
    .IF eax == 2
        mov eax, TRUE
    .ELSE    
        mov eax, FALSE
    .ENDIF
    ret
ConsoleStarted ENDP

IEEX_ALIGN
;------------------------------------------------------------------------------
; ConsoleSendEnterKey
;------------------------------------------------------------------------------
ConsoleSendEnterKey PROC
    Invoke GetConsoleWindow
    .IF eax != 0
        Invoke SendMessage, eax, WM_CHAR, VK_RETURN, 0
    .ENDIF
    ret
ConsoleSendEnterKey ENDP

IEEX_ALIGN
;------------------------------------------------------------------------------
; ConsoleAttach
;------------------------------------------------------------------------------
ConsoleAttach PROC
    Invoke AttachConsole, ATTACH_PARENT_PROCESS
    ret
ConsoleAttach ENDP

IEEX_ALIGN
;------------------------------------------------------------------------------
; Read output from the child process's pipe for STDOUT
; and write to the parent process's pipe for STDOUT. 
; Stop when there is no more data. 
;------------------------------------------------------------------------------
ReadFromPipe PROC
    LOCAL dwTotalBytesToRead:DWORD
    LOCAL dwRead:DWORD
    LOCAL dwWritten:DWORD
    LOCAL hParentStdOut:DWORD
    LOCAL hParentStdErr:DWORD
    LOCAL bSuccess:DWORD

    IFDEF DEBUG32
    PrintText 'ReadFromPipe'
    ENDIF

    mov bSuccess, FALSE
    Invoke GetStdHandle, STD_OUTPUT_HANDLE
    mov hParentStdOut, eax
    Invoke GetStdHandle, STD_ERROR_HANDLE
    mov hParentStdErr, eax

    IFDEF DEBUG32
    PrintText 'ReadFromPipe Loop'
    ENDIF

    .WHILE TRUE
        Invoke GetExitCodeProcess, pi.hProcess, Addr ExitCode
        .IF eax == 0
            IFDEF DEBUG32
            PrintText 'GetExitCodeProcess error'
            Invoke GetLastError
            PrintDec eax
            ENDIF
        .ENDIF
        .IF ExitCode != STILL_ACTIVE
            IFDEF DEBUG32
            PrintText 'Exit from ReadFromPipe::GetExitCodeProcess'
            ENDIF
            ret
        .ENDIF
        
        Invoke PeekNamedPipe, hChildStd_OUT_Rd, NULL, NULL, NULL, Addr dwTotalBytesToRead, NULL
        .IF eax == 0
            IFDEF DEBUG32
            PrintText 'PeekNamedPipe Error'
            Invoke GetLastError
            PrintDec eax
            ENDIF
        .ENDIF
        
        .IF dwTotalBytesToRead != 0
            IFDEF DEBUG32
            PrintDec dwTotalBytesToRead
            ENDIF
            Invoke ReadFile, hChildStd_OUT_Rd, Addr PIPEBUFFER, SIZEOF PIPEBUFFER, Addr dwRead, NULL
            mov bSuccess, eax
            .IF bSuccess == FALSE || dwRead == 0
                IFDEF DEBUG32
                PrintText 'Exit from ReadFromPipe::ReadFile'
                ENDIF
                ret
            .ENDIF
            
            .IF hLogFile != 0
                Invoke WriteFile, hLogFile, Addr PIPEBUFFER, dwRead, Addr dwWritten, NULL
            .ENDIF
            
            Invoke WriteFile, hParentStdOut, Addr PIPEBUFFER, dwRead, Addr dwWritten, NULL
            mov bSuccess, eax
            .IF bSuccess == FALSE
                IFDEF DEBUG32
                PrintText 'Exit from ReadFromPipe::WriteFile'
                ENDIF
                ret
            .ENDIF
        .ENDIF
        
        Invoke Sleep, 100
        
    .ENDW
    
    ret
ReadFromPipe ENDP





















