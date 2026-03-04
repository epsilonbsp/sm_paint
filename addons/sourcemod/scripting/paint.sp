// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 EpsilonBSP

#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>

#define PLUGIN_VERSION    "1.0.0"

#define PAINT_DISTANCE_SQ 1.0
#define MAX_DECALS        2048
#define MAX_PAINT_PLAYERS MAXPLAYERS

public Plugin myinfo = {
    name =        "Paint",
    author =      "EpsilonBSP",
    description = "Make it possible for players to paint on walls",
    version =     PLUGIN_VERSION,
    url =         "https://github.com/epsilonbsp/sm_paint"
}

// Globals
int   g_PlayerPaintColor[MAXPLAYERS + 1];
int   g_PlayerPaintSize[MAXPLAYERS + 1];
float g_fLastPaint[MAXPLAYERS + 1][3];
bool  g_bIsPainting[MAXPLAYERS + 1];

// Shared decal buffer
float g_fDecalPos[MAX_DECALS][3];
int   g_iDecalSprite[MAX_DECALS];
int   g_iDecalCount;
int   g_iDecalHead;

// Per-player client-side decal buffers
float g_fClientDecalPos[MAX_PAINT_PLAYERS + 1][MAX_DECALS][3];
int   g_iClientDecalSprite[MAX_PAINT_PLAYERS + 1][MAX_DECALS];
int   g_iClientDecalCount[MAX_PAINT_PLAYERS + 1];
int   g_iClientDecalHead[MAX_PAINT_PLAYERS + 1];

bool  g_bClientSidePaint[MAXPLAYERS + 1];
bool  g_bPaintMenuOpen[MAXPLAYERS + 1];
bool  g_bIsErasing[MAXPLAYERS + 1];
int   g_iHoveredDecal[MAXPLAYERS + 1];
bool  g_bLastAttack[MAXPLAYERS + 1];

int   g_iGlowSprite;

// DB
Database g_hDatabase;

// Per-decal color + size stored alongside the client-side buffer (needed for DB save/load)
int g_iClientDecalColor[MAX_PAINT_PLAYERS + 1][MAX_DECALS];
int g_iClientDecalSize[MAX_PAINT_PLAYERS + 1][MAX_DECALS];

// Cookies
Handle g_hPlayerPaintColor;
Handle g_hPlayerPaintSize;
Handle g_hClientSidePaint;

// Color name, file name
char g_cPaintColors[][][64] = {
    {"Random",     "random" },
    {"Black",      "paint_black"},
    {"Blue",       "paint_blue"},
    {"Brown",      "paint_brown"},
    {"Cyan",       "paint_cyan"},
    {"Dark Green", "paint_darkgreen"},
    {"Green",      "paint_green"},
    {"Light Blue", "paint_lightblue"},
    {"Light Pink", "paint_lightpink"},
    {"Orange",     "paint_orange"},
    {"Pink",       "paint_pink"},
    {"Purple",     "paint_purple"},
    {"Red",        "paint_red"},
    {"White",      "paint_white"},
    {"Yellow",     "paint_yellow"}
};

// Size name, size suffix
char g_cPaintSizes[][][64] = {
    {"Very Small", "_0"},
    {"Small",      "_1"},
    {"Medium",     "_2"},
    {"Large",      "_3"},
    {"Very Large", "_4"}
};

int g_Sprites[sizeof(g_cPaintColors) - 1][sizeof(g_cPaintSizes)];

public void OnPluginStart() {
    CreateConVar("paint_version", PLUGIN_VERSION, "Paint plugin version", FCVAR_NOTIFY);

    for (int i = 1; i <= MaxClients; i++) {
        g_iHoveredDecal[i] = -1;
    }

    g_hPlayerPaintColor = RegClientCookie("paint_playerpaintcolor", "paint_playerpaintcolor", CookieAccess_Protected);
    g_hPlayerPaintSize  = RegClientCookie("paint_playerpaintsize",  "paint_playerpaintsize",  CookieAccess_Protected);
    g_hClientSidePaint  = RegClientCookie("paint_clientside",       "paint_clientside",       CookieAccess_Protected);

    ConnectDB();

    RegConsoleCmd("sm_paint",           cmd_PaintMenu);
    RegConsoleCmd("sm_paintcolor",      cmd_PaintColor);
    RegConsoleCmd("sm_paintsize",       cmd_PaintSize);
    RegConsoleCmd("sm_clientsidepaint", cmd_ToggleClientSide);
    RegConsoleCmd("+paint", cmd_EnablePaint);
    RegConsoleCmd("-paint", cmd_DisablePaint);

    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            OnClientCookiesCached(i);
        }
    }
}

public void OnClientCookiesCached(int client) {
    char sValue[64];

    GetClientCookie(client, g_hPlayerPaintColor, sValue, sizeof(sValue));
    g_PlayerPaintColor[client] = StringToInt(sValue);

    GetClientCookie(client, g_hPlayerPaintSize, sValue, sizeof(sValue));
    g_PlayerPaintSize[client] = StringToInt(sValue);

    GetClientCookie(client, g_hClientSidePaint, sValue, sizeof(sValue));
    g_bClientSidePaint[client] = view_as<bool>(StringToInt(sValue));
}

public void OnClientDisconnect(int client) {
    if (g_iClientDecalCount[client] > 0) {
        g_iClientDecalCount[client] = 0;
        g_iClientDecalHead[client]  = 0;
    }

    g_bIsErasing[client]    = false;
    g_iHoveredDecal[client] = -1;
    g_bLastAttack[client]   = false;
}

public void OnMapStart() {
    g_iDecalCount = 0;
    g_iDecalHead  = 0;

    for (int i = 1; i <= MAX_PAINT_PLAYERS; i++) {
        g_iClientDecalCount[i] = 0;
        g_iClientDecalHead[i]  = 0;
    }

    g_iGlowSprite = PrecacheModel("sprites/glow01.vmt", true);

    char buffer[PLATFORM_MAX_PATH];

    AddFileToDownloadsTable("materials/decals/paint/paint_decal.vtf");

    for (int color = 1; color < sizeof(g_cPaintColors); color++) {
        for (int size = 0; size < sizeof(g_cPaintSizes); size++) {
            Format(buffer, sizeof(buffer), "decals/paint/%s%s.vmt", g_cPaintColors[color][1], g_cPaintSizes[size][1]);
            g_Sprites[color - 1][size] = PrecachePaint(buffer);
        }
    }

    CreateTimer(0.1, Timer_Paint, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientPutInServer(int client) {
    CreateTimer(1.0, Timer_SendDecals, client);
}

public Action Timer_SendDecals(Handle timer, int client) {
    if (!IsClientInGame(client)) {
        return Plugin_Stop;
    }

    // Always send shared buffer first
    int start = (g_iDecalCount < MAX_DECALS) ? 0 : g_iDecalHead;

    for (int i = 0; i < g_iDecalCount; i++) {
        int idx = (start + i) % MAX_DECALS;
        TE_SetupWorldDecal(g_fDecalPos[idx], g_iDecalSprite[idx]);
        TE_SendToClient(client);
    }

    // If client-side mode is on, auto-load their saved decals from DB
    if (g_bClientSidePaint[client]) {
        FetchClientDecals(client);
    }

    return Plugin_Stop;
}

public Action cmd_EnablePaint(int client, int args) {
    TraceEye(client, g_fLastPaint[client]);
    g_bIsPainting[client] = true;

    return Plugin_Handled;
}

public Action cmd_DisablePaint(int client, int args) {
    g_bIsPainting[client] = false;

    if (g_bPaintMenuOpen[client]) {
        OpenPaintMenu(client);
    }

    return Plugin_Handled;
}

public Action cmd_PaintMenu(int client, int args) {
    OpenPaintMenu(client);

    return Plugin_Handled;
}

public Action cmd_PaintColor(int client, int args) {
    OpenColorMenu(client);

    return Plugin_Handled;
}

public Action cmd_PaintSize(int client, int args) {
    OpenSizeMenu(client);

    return Plugin_Handled;
}

public Action cmd_ToggleClientSide(int client, int args) {
    g_bClientSidePaint[client] = !g_bClientSidePaint[client];
    g_iHoveredDecal[client]    = -1;

    char sValue[4];
    IntToString(g_bClientSidePaint[client] ? 1 : 0, sValue, sizeof(sValue));
    SetClientCookie(client, g_hClientSidePaint, sValue);

    ClientCommand(client, "r_cleardecals");
    SendActiveDecalsToClient(client);

    PrintToChat(client, "[SM] Client-side paint: \x10%s", g_bClientSidePaint[client] ? "ON" : "OFF");

    return Plugin_Handled;
}

void OpenPaintMenu(int client) {
    g_bPaintMenuOpen[client] = true;

    int shownCount = g_bClientSidePaint[client] ?
        g_iClientDecalCount[client] :
        g_iDecalCount;

    Menu menu = new Menu(PaintMenuHandle);
    menu.SetTitle(
        "Paint:\nColor: %s | Size: %s\nDecals: %d / %d\nMode: %s",
        g_cPaintColors[g_PlayerPaintColor[client]][0],
        g_cPaintSizes[g_PlayerPaintSize[client]][0],
        shownCount,
        MAX_DECALS,
        g_bClientSidePaint[client] ? "Client-side" : "Shared"
    );
    menu.AddItem("toggle",       g_bIsPainting[client] ? "[x] Painting" : "[ ] Painting");
    menu.AddItem("erase_toggle", g_bIsErasing[client]  ? "[x] Erasing"  : "[ ] Erasing");
    menu.AddItem("erase_all", "Erase All");
    menu.AddItem("color", "Paint Color");
    menu.AddItem("size", "Paint Size");

    if (g_bClientSidePaint[client]) {
        menu.AddItem("save_paint", "Save Paint");
        menu.AddItem("load_paint", "Load Paint");
    }

    menu.AddItem("clientside", g_bClientSidePaint[client] ? "[x] Client-side" : "[ ] Client-side");
    menu.Display(client, 20);
}

void OpenColorMenu(int client, int firstItem = 0) {
    Menu menu = new Menu(PaintColorMenuHandle);
    menu.ExitBackButton = true;
    menu.SetTitle("Select Paint Color:\nCurrent: %s", g_cPaintColors[g_PlayerPaintColor[client]][0]);

    for (int i = 0; i < sizeof(g_cPaintColors); i++) {
        menu.AddItem(g_cPaintColors[i][0], g_cPaintColors[i][0]);
    }

    menu.DisplayAt(client, firstItem, 20);
}

void OpenSizeMenu(int client, int firstItem = 0) {
    Menu menu = new Menu(PaintSizeMenuHandle);
    menu.ExitBackButton = true;
    menu.SetTitle("Select Paint Size:\nCurrent: %s", g_cPaintSizes[g_PlayerPaintSize[client]][0]);

    for (int i = 0; i < sizeof(g_cPaintSizes); i++) {
        menu.AddItem(g_cPaintSizes[i][0], g_cPaintSizes[i][0]);
    }

    menu.DisplayAt(client, firstItem, 20);
}

public void PaintMenuHandle(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        char info[32];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, "toggle")) {
            g_bIsPainting[param1] = !g_bIsPainting[param1];

            if (g_bIsPainting[param1]) {
                TraceEye(param1, g_fLastPaint[param1]);
                g_bIsErasing[param1]    = false;
                g_iHoveredDecal[param1] = -1;
            }

            OpenPaintMenu(param1);
        } else if (StrEqual(info, "erase_toggle")) {
            g_bIsErasing[param1] = !g_bIsErasing[param1];

            if (g_bIsErasing[param1]) {
                g_bIsPainting[param1] = false;
            }

            g_iHoveredDecal[param1] = -1;
            OpenPaintMenu(param1);
        } else if (StrEqual(info, "clientside")) {
            g_bClientSidePaint[param1] = !g_bClientSidePaint[param1];
            g_iHoveredDecal[param1]    = -1;

            char sValue[4];
            IntToString(g_bClientSidePaint[param1] ? 1 : 0, sValue, sizeof(sValue));
            SetClientCookie(param1, g_hClientSidePaint, sValue);

            ClientCommand(param1, "r_cleardecals");
            SendActiveDecalsToClient(param1);

            OpenPaintMenu(param1);
        } else if (StrEqual(info, "erase_all")) {
            EraseAll(param1);
            OpenPaintMenu(param1);
        } else {
            g_bPaintMenuOpen[param1] = false;

            if (StrEqual(info, "color")) {
                OpenColorMenu(param1);
            } else if (StrEqual(info, "size")) {
                OpenSizeMenu(param1);
            } else if (StrEqual(info, "save_paint")) {
                OpenSaveConfirmMenu(param1);
            } else if (StrEqual(info, "load_paint")) {
                OpenLoadConfirmMenu(param1);
            }
        }
    } else if (action == MenuAction_Cancel) {
        if (param2 != MenuCancel_Interrupted) {
            g_bPaintMenuOpen[param1] = false;
        }
    } else if (action == MenuAction_End) {
        delete menu;
    }
}

public void PaintColorMenuHandle(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        SetClientPaintColor(param1, param2);
        OpenColorMenu(param1, param2 - (param2 % menu.Pagination));
    } else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack) {
        OpenPaintMenu(param1);
    } else if (action == MenuAction_End) {
        delete menu;
    }
}

public void PaintSizeMenuHandle(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        SetClientPaintSize(param1, param2);
        OpenSizeMenu(param1, param2 - (param2 % menu.Pagination));
    } else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack) {
        OpenPaintMenu(param1);
    } else if (action == MenuAction_End) {
        delete menu;
    }
}

public void Timer_Paint(Handle timer) {
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || !IsPlayerAlive(i)) {
            continue;
        }

        static float pos[3];

        if (g_bIsPainting[i]) {
            TraceEye(i, pos);

            if (GetVectorDistance(pos, g_fLastPaint[i], true) > PAINT_DISTANCE_SQ) {
                AddPaint(i, pos, g_PlayerPaintColor[i], g_PlayerPaintSize[i]);
                g_fLastPaint[i] = pos;
            }
        }

        if (g_bIsErasing[i]) {
            TraceEye(i, pos);
            int nearest = FindNearestDecal(i, pos, 64.0);
            g_iHoveredDecal[i] = nearest;

            if (nearest != -1) {
                float glowPos[3];

                if (g_bClientSidePaint[i]) {
                    glowPos = g_fClientDecalPos[i][nearest];
                } else {
                    glowPos = g_fDecalPos[nearest];
                }

                TE_SetupGlowSprite(glowPos, g_iGlowSprite, 0.15, 3.0, 150);
                TE_SendToClient(i);
            }
        }
    }
}

int FindNearestDecal(int client, const float pos[3], float maxDist) {
    int   nearest   = -1;
    float nearestSq = maxDist * maxDist;

    if (g_bClientSidePaint[client]) {
        int start = (g_iClientDecalCount[client] < MAX_DECALS) ? 0 : g_iClientDecalHead[client];

        for (int i = 0; i < g_iClientDecalCount[client]; i++) {
            int   idx    = (start + i) % MAX_DECALS;
            float distSq = GetVectorDistance(pos, g_fClientDecalPos[client][idx], true);

            if (distSq < nearestSq) {
                nearestSq = distSq;
                nearest = idx;
            }
        }
    } else {
        int start = (g_iDecalCount < MAX_DECALS) ? 0 : g_iDecalHead;

        for (int i = 0; i < g_iDecalCount; i++) {
            int   idx    = (start + i) % MAX_DECALS;
            float distSq = GetVectorDistance(pos, g_fDecalPos[idx], true);

            if (distSq < nearestSq) {
                nearestSq = distSq;
                nearest = idx;
            }
        }
    }

    return nearest;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon) {
    bool using_ = view_as<bool>(buttons & IN_USE);

    if (g_bIsErasing[client] && using_ && !g_bLastAttack[client] && g_iHoveredDecal[client] != -1) {
        EraseDecal(client, g_iHoveredDecal[client]);
        g_iHoveredDecal[client] = -1;
    }

    g_bLastAttack[client] = using_;

    return Plugin_Continue;
}

void EraseDecal(int client, int idx) {
    if (g_bClientSidePaint[client]) {
        int lastIdx = (g_iClientDecalCount[client] < MAX_DECALS) ?
            g_iClientDecalCount[client] - 1 :
            (g_iClientDecalHead[client] - 1 + MAX_DECALS) % MAX_DECALS;

        if (idx != lastIdx) {
            g_fClientDecalPos[client][idx]    = g_fClientDecalPos[client][lastIdx];
            g_iClientDecalSprite[client][idx] = g_iClientDecalSprite[client][lastIdx];
            g_iClientDecalColor[client][idx]  = g_iClientDecalColor[client][lastIdx];
            g_iClientDecalSize[client][idx]   = g_iClientDecalSize[client][lastIdx];
        }

        g_iClientDecalCount[client]--;
        g_iClientDecalHead[client] = (g_iClientDecalCount[client] < MAX_DECALS) ?
            g_iClientDecalCount[client] : lastIdx;

        // Clear and replay both shared + client-side decals for this client only
        ClientCommand(client, "r_cleardecals");
        SendAllDecalsToClient(client);
    } else {
        int lastIdx = (g_iDecalCount < MAX_DECALS) ?
            g_iDecalCount - 1 :
            (g_iDecalHead - 1 + MAX_DECALS) % MAX_DECALS;

        if (idx != lastIdx) {
            g_fDecalPos[idx]    = g_fDecalPos[lastIdx];
            g_iDecalSprite[idx] = g_iDecalSprite[lastIdx];
        }

        g_iDecalCount--;
        g_iDecalHead = (g_iDecalCount < MAX_DECALS) ? g_iDecalCount : lastIdx;

        for (int i = 1; i <= MaxClients; i++) {
            if (IsClientInGame(i)) {
                ClientCommand(i, "r_cleardecals");
            }
        }

        RepaintSharedToAll();

        // Also replay each client's own client-side decals back to them
        for (int i = 1; i <= MaxClients; i++) {
            if (IsClientInGame(i) && g_iClientDecalCount[i] > 0) {
                int start = (g_iClientDecalCount[i] < MAX_DECALS) ? 0 : g_iClientDecalHead[i];

                for (int j = 0; j < g_iClientDecalCount[i]; j++) {
                    int decalIdx = (start + j) % MAX_DECALS;
                    TE_SetupWorldDecal(g_fClientDecalPos[i][decalIdx], g_iClientDecalSprite[i][decalIdx]);
                    TE_SendToClient(i);
                }
            }
        }
    }

    for (int i = 1; i <= MaxClients; i++) {
        if (g_bPaintMenuOpen[i]) {
            OpenPaintMenu(i);
        }
    }
}

void EraseAll(int client) {
    if (g_bClientSidePaint[client]) {
        g_iClientDecalCount[client] = 0;
        g_iClientDecalHead[client]  = 0;
        g_iHoveredDecal[client]     = -1;

        ClientCommand(client, "r_cleardecals");
        SendAllDecalsToClient(client); // Replay shared buffer so they still see others' paint
    } else {
        g_iDecalCount = 0;
        g_iDecalHead  = 0;

        for (int i = 1; i <= MaxClients; i++) {
            if (IsClientInGame(i)) {
                ClientCommand(i, "r_cleardecals");
            }

            g_iHoveredDecal[i] = -1;
        }

        // Replay each client's own client-side decals back to them
        for (int i = 1; i <= MaxClients; i++) {
            if (IsClientInGame(i) && g_iClientDecalCount[i] > 0) {
                int start = (g_iClientDecalCount[i] < MAX_DECALS) ? 0 : g_iClientDecalHead[i];

                for (int j = 0; j < g_iClientDecalCount[i]; j++) {
                    int idx = (start + j) % MAX_DECALS;
                    TE_SetupWorldDecal(g_fClientDecalPos[i][idx], g_iClientDecalSprite[i][idx]);
                    TE_SendToClient(i);
                }
            }
        }
    }
}

void AddPaint(int client, float pos[3], int paint = 0, int size = 0) {
    if (paint == 0) {
        paint = GetRandomInt(1, sizeof(g_cPaintColors) - 1);
    }

    int sprite = g_Sprites[paint - 1][size];

    if (g_bClientSidePaint[client]) {
        g_fClientDecalPos[client][g_iClientDecalHead[client]]    = pos;
        g_iClientDecalSprite[client][g_iClientDecalHead[client]] = sprite;
        g_iClientDecalColor[client][g_iClientDecalHead[client]]  = paint;
        g_iClientDecalSize[client][g_iClientDecalHead[client]]   = size;
        g_iClientDecalHead[client] = (g_iClientDecalHead[client] + 1) % MAX_DECALS;

        if (g_iClientDecalCount[client] < MAX_DECALS) {
            g_iClientDecalCount[client]++;
        }

        TE_SetupWorldDecal(pos, sprite);
        TE_SendToClient(client);
    } else {
        g_fDecalPos[g_iDecalHead]    = pos;
        g_iDecalSprite[g_iDecalHead] = sprite;
        g_iDecalHead = (g_iDecalHead + 1) % MAX_DECALS;

        if (g_iDecalCount < MAX_DECALS) {
            g_iDecalCount++;
        }

        TE_SetupWorldDecal(pos, sprite);
        TE_SendToAll();
    }

    for (int i = 1; i <= MaxClients; i++) {
        if (g_bPaintMenuOpen[i]) {
            OpenPaintMenu(i);
        }
    }
}

void RepaintSharedToAll() {
    int start = (g_iDecalCount < MAX_DECALS) ? 0 : g_iDecalHead;

    for (int i = 0; i < g_iDecalCount; i++) {
        int idx = (start + i) % MAX_DECALS;
        TE_SetupWorldDecal(g_fDecalPos[idx], g_iDecalSprite[idx]);
        TE_SendToAll();
    }
}

// Sends only the buffer that matches the client's current mode.
// Use this when switching modes so decals from the other buffer don't bleed through.
void SendActiveDecalsToClient(int client) {
    if (g_bClientSidePaint[client]) {
        int start = (g_iClientDecalCount[client] < MAX_DECALS) ? 0 : g_iClientDecalHead[client];

        for (int i = 0; i < g_iClientDecalCount[client]; i++) {
            int idx = (start + i) % MAX_DECALS;
            TE_SetupWorldDecal(g_fClientDecalPos[client][idx], g_iClientDecalSprite[client][idx]);
            TE_SendToClient(client);
        }
    } else {
        int start = (g_iDecalCount < MAX_DECALS) ? 0 : g_iDecalHead;

        for (int i = 0; i < g_iDecalCount; i++) {
            int idx = (start + i) % MAX_DECALS;

            TE_SetupWorldDecal(g_fDecalPos[idx], g_iDecalSprite[idx]);
            TE_SendToClient(client);
        }
    }
}

// Sends shared buffer + client's own buffer (used for late-join replay and erase repaint).
void SendAllDecalsToClient(int client) {
    // Shared buffer
    int start = (g_iDecalCount < MAX_DECALS) ? 0 : g_iDecalHead;

    for (int i = 0; i < g_iDecalCount; i++) {
        int idx = (start + i) % MAX_DECALS;

        TE_SetupWorldDecal(g_fDecalPos[idx], g_iDecalSprite[idx]);
        TE_SendToClient(client);
    }

    // Client's own buffer
    if (g_iClientDecalCount[client] > 0) {
        start = (g_iClientDecalCount[client] < MAX_DECALS) ? 0 : g_iClientDecalHead[client];

        for (int i = 0; i < g_iClientDecalCount[client]; i++) {
            int idx = (start + i) % MAX_DECALS;

            TE_SetupWorldDecal(g_fClientDecalPos[client][idx], g_iClientDecalSprite[client][idx]);
            TE_SendToClient(client);
        }
    }
}

int PrecachePaint(char[] filename) {
    char tmpPath[PLATFORM_MAX_PATH];

    Format(tmpPath, sizeof(tmpPath), "materials/%s", filename);
    AddFileToDownloadsTable(tmpPath);

    return PrecacheDecal(filename, true);
}

void SetClientPaintColor(int client, int paint) {
    char sValue[64];
    g_PlayerPaintColor[client] = paint;
    IntToString(paint, sValue, sizeof(sValue));
    SetClientCookie(client, g_hPlayerPaintColor, sValue);

    PrintToChat(client, "[SM] Paint color now: \x10%s", g_cPaintColors[paint][0]);
}

void SetClientPaintSize(int client, int size) {
    char sValue[64];
    g_PlayerPaintSize[client] = size;
    IntToString(size, sValue, sizeof(sValue));
    SetClientCookie(client, g_hPlayerPaintSize, sValue);

    PrintToChat(client, "[SM] Paint size now: \x10%s", g_cPaintSizes[size][0]);
}

void OpenSaveConfirmMenu(int client) {
    Menu menu = new Menu(SaveConfirmMenuHandle);
    menu.SetTitle("Save Paint?\nOverwrites your saved decals for this map.");
    menu.AddItem("yes", "Yes, save");
    menu.AddItem("no",  "No, go back");
    menu.ExitButton = false;
    menu.Display(client, 20);
}

public void SaveConfirmMenuHandle(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        char info[8];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, "yes")) {
            SaveClientDecals(param1);
        }

        OpenPaintMenu(param1);
    } else if (action == MenuAction_Cancel && param2 != MenuCancel_Interrupted) {
        OpenPaintMenu(param1);
    } else if (action == MenuAction_End) {
        delete menu;
    }
}

void OpenLoadConfirmMenu(int client) {
    Menu menu = new Menu(LoadConfirmMenuHandle);
    menu.SetTitle("Load Paint?\nReplaces current decals with your saved ones for this map.");
    menu.AddItem("yes", "Yes, load");
    menu.AddItem("no",  "No, go back");
    menu.ExitButton = false;
    menu.Display(client, 20);
}

public void LoadConfirmMenuHandle(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        char info[8];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, "yes")) {
            ClientCommand(param1, "r_cleardecals");
            int start = (g_iDecalCount < MAX_DECALS) ? 0 : g_iDecalHead;

            for (int i = 0; i < g_iDecalCount; i++) {
                int idx = (start + i) % MAX_DECALS;
                TE_SetupWorldDecal(g_fDecalPos[idx], g_iDecalSprite[idx]);
                TE_SendToClient(param1);
            }

            FetchClientDecals(param1); // async; DB_OnFetchDecals will reopen paint menu when done
        } else {
            OpenPaintMenu(param1);
        }
    } else if (action == MenuAction_Cancel && param2 != MenuCancel_Interrupted) {
        OpenPaintMenu(param1);
    } else if (action == MenuAction_End) {
        delete menu;
    }
}

void ConnectDB() {
    KeyValues kv = new KeyValues("paint");
    kv.SetString("driver",   "sqlite");
    kv.SetString("database", "paint");

    char error[256];
    g_hDatabase = SQL_ConnectCustom(kv, error, sizeof(error), false);
    delete kv;

    if (g_hDatabase == null) {
        LogError("[Paint] DB connect failed: %s", error);

        return;
    }

    SQL_FastQuery(g_hDatabase, "CREATE TABLE IF NOT EXISTS paint_decals (steamid VARCHAR(32) NOT NULL, map VARCHAR(128) NOT NULL, pos_x FLOAT NOT NULL, pos_y FLOAT NOT NULL, pos_z FLOAT NOT NULL, color INT NOT NULL, size INT NOT NULL)");
}

void SaveClientDecals(int client) {
    if (g_hDatabase == null) {
        PrintToChat(client, "[SM] Database unavailable.");

        return;
    }

    if (!g_bClientSidePaint[client]) {
        PrintToChat(client, "[SM] Save is only available in client-side mode.");

        return;
    }

    char steamid[32], map[128], sSteamId[64], sMap[256], query[512];
    GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));
    GetCurrentMap(map, sizeof(map));
    g_hDatabase.Escape(steamid, sSteamId, sizeof(sSteamId));
    g_hDatabase.Escape(map,     sMap,     sizeof(sMap));

    Format(query, sizeof(query), "DELETE FROM paint_decals WHERE steamid='%s' AND map='%s'", sSteamId, sMap);
    SQL_FastQuery(g_hDatabase, query);

    int count = g_iClientDecalCount[client];

    if (count > 0) {
        SQL_FastQuery(g_hDatabase, "BEGIN");
        int start = (count < MAX_DECALS) ? 0 : g_iClientDecalHead[client];

        for (int i = 0; i < count; i++) {
            int idx = (start + i) % MAX_DECALS;

            Format(query, sizeof(query),
                "INSERT INTO paint_decals (steamid,map,pos_x,pos_y,pos_z,color,size) VALUES ('%s','%s',%f,%f,%f,%d,%d)",
                sSteamId, sMap,
                g_fClientDecalPos[client][idx][0],
                g_fClientDecalPos[client][idx][1],
                g_fClientDecalPos[client][idx][2],
                g_iClientDecalColor[client][idx],
                g_iClientDecalSize[client][idx]
            );

            SQL_FastQuery(g_hDatabase, query);
        }
    
        SQL_FastQuery(g_hDatabase, "COMMIT");
    }

    PrintToChat(client, "[SM] Paint saved (%d decals).", count);
}

void FetchClientDecals(int client) {
    if (g_hDatabase == null || !IsClientInGame(client) || IsFakeClient(client)) {
        return;
    }

    char steamid[32], map[128], sSteamId[64], sMap[256], query[512];
    GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));
    GetCurrentMap(map, sizeof(map));
    g_hDatabase.Escape(steamid, sSteamId, sizeof(sSteamId));
    g_hDatabase.Escape(map,     sMap,     sizeof(sMap));

    Format(query, sizeof(query),
        "SELECT pos_x,pos_y,pos_z,color,size FROM paint_decals WHERE steamid='%s' AND map='%s'",
        sSteamId, sMap);

    DataPack dp = new DataPack();
    dp.WriteCell(client);
    dp.WriteCell(GetClientSerial(client));
    g_hDatabase.Query(DB_OnFetchDecals, query, dp);
}

public void DB_OnFetchDecals(Database db, DBResultSet results, const char[] error, DataPack dp) {
    dp.Reset();
    int client = dp.ReadCell();
    int serial = dp.ReadCell();
    delete dp;

    if (results == null) {
        LogError("[Paint] DB fetch error: %s", error);

        return;
    }

    if (!IsClientInGame(client) || GetClientSerial(client) != serial) return;

    // Reset in-memory buffer before populating from DB
    g_iClientDecalCount[client] = 0;
    g_iClientDecalHead[client]  = 0;

    int loaded = 0;

    while (results.FetchRow()) {
        float pos[3];
        pos[0]    = results.FetchFloat(0);
        pos[1]    = results.FetchFloat(1);
        pos[2]    = results.FetchFloat(2);
        int color = results.FetchInt(3);
        int size  = results.FetchInt(4);

        if (color < 1 || color >= sizeof(g_cPaintColors) || size < 0 || size >= sizeof(g_cPaintSizes)) {
            continue;
        }

        int sprite = g_Sprites[color - 1][size];
        int head   = g_iClientDecalHead[client];

        g_fClientDecalPos[client][head]    = pos;
        g_iClientDecalSprite[client][head] = sprite;
        g_iClientDecalColor[client][head]  = color;
        g_iClientDecalSize[client][head]   = size;

        g_iClientDecalHead[client] = (head + 1) % MAX_DECALS;

        if (g_iClientDecalCount[client] < MAX_DECALS) {
            g_iClientDecalCount[client]++;
        }

        TE_SetupWorldDecal(pos, sprite);
        TE_SendToClient(client);
        loaded++;
    }

    if (loaded > 0) {
        PrintToChat(client, "[SM] Loaded %d paint decals.", loaded);

        if (g_bPaintMenuOpen[client]) {
            OpenPaintMenu(client);
        }
    }
}

stock void TE_SetupWorldDecal(const float vecOrigin[3], int index) {
    TE_Start("World Decal");
    TE_WriteVector("m_vecOrigin", vecOrigin);
    TE_WriteNum("m_nIndex", index);
}

stock void TraceEye(int client, float pos[3]) {
    float vAngles[3], vOrigin[3];
    GetClientEyePosition(client, vOrigin);
    GetClientEyeAngles(client, vAngles);

    TR_TraceRayFilter(vOrigin, vAngles, MASK_SHOT, RayType_Infinite, TraceEntityFilterPlayer);

    if (TR_DidHit()) {
        TR_GetEndPosition(pos);
    }
}

public bool TraceEntityFilterPlayer(int entity, int contentsMask) {
    return (entity > MaxClients || !entity);
}
