#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION  "1.2"
#define MAX_TAG_LENGTH  32
#define MAX_NAME_LENGTH 64

// ============================================================
// CVars
// ============================================================
ConVar g_cvDelay;
ConVar g_cvDuration;

// ============================================================
// Dados dos jogadores em memória
// ============================================================
char g_sTag[MAXPLAYERS+1][MAX_TAG_LENGTH];       // tag atual (sem colchetes)
char g_sCustomName[MAXPLAYERS+1][MAX_NAME_LENGTH]; // nome customizado (ou vazio = usa nome Steam)
char g_sSteamName[MAXPLAYERS+1][MAX_NAME_LENGTH];  // nome original do Steam ao conectar
bool g_bSpawned[MAXPLAYERS+1];

// ============================================================
// Banco de dados
// ============================================================
Database g_hDB = null;

// ============================================================
// Prefixos reservados para admins
// ============================================================
static const char g_sReservedPrefixes[][] = { "*", "#", "@" };

// ============================================================
// Info do plugin
// ============================================================
public Plugin myinfo =
{
    name        = "Tags e Nomes Customizados",
    author      = "Seu Nome",
    description = "Jogadores podem definir tag e nome customizado",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================
// Inicialização
// ============================================================
public void OnPluginStart()
{
    g_cvDelay    = CreateConVar("sm_tag_delay",    "10.0", "Segundos apos spawnar para exibir a mensagem", FCVAR_NOTIFY);
    g_cvDuration = CreateConVar("sm_tag_duration", "8.0",  "Segundos que a mensagem fica visivel na tela",  FCVAR_NOTIFY);

    // Comandos de jogador
    RegConsoleCmd("sm_tag",       Cmd_SetTag,       "Define sua tag: !tag <texto>");
    RegConsoleCmd("sm_cleartag",  Cmd_ClearTag,     "Remove sua tag");
    RegConsoleCmd("sm_nome",      Cmd_SetName,      "Muda seu nome: !nome <texto>");
    RegConsoleCmd("sm_clearnome", Cmd_ClearName,    "Remove seu nome customizado e volta ao nome Steam");

    // Comandos de admin
    RegAdminCmd("sm_settag",          Cmd_AdminSetTag,   ADMFLAG_GENERIC, "Admin: define tag de um jogador");
    RegAdminCmd("sm_cleartag_player", Cmd_AdminClearTag, ADMFLAG_GENERIC, "Admin: remove tag de um jogador");
    RegAdminCmd("sm_setnome",         Cmd_AdminSetName,  ADMFLAG_GENERIC, "Admin: define nome de um jogador");
    RegAdminCmd("sm_clearnome_player",Cmd_AdminClearName,ADMFLAG_GENERIC, "Admin: remove nome customizado de um jogador");

    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);

    AutoExecConfig(true, "tags_customizadas");
}

// ============================================================
// Banco de dados — inicializa APÓS todos os plugins carregarem
// ============================================================
public void OnAllPluginsLoaded()
{
    DB_Connect();
}

void DB_Connect()
{
    char sError[256];
    g_hDB = SQLite_UseDatabase("tags_customizadas", sError, sizeof(sError));

    if (g_hDB == null)
    {
        LogError("[Tags] Erro ao conectar ao banco de dados: %s", sError);
        return;
    }

    // Tabela agora tem tag e nome customizado
    g_hDB.Query(DB_OnTableCreated,
        "CREATE TABLE IF NOT EXISTS player_data ( \
            steamid     TEXT PRIMARY KEY, \
            tag         TEXT NOT NULL DEFAULT '', \
            custom_name TEXT NOT NULL DEFAULT '' \
        )");
}

public void DB_OnTableCreated(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
        LogError("[Tags] Erro ao criar tabela: %s", error);
}

// ============================================================
// Jogador entra no servidor
// ============================================================
public void OnClientPutInServer(int client)
{
    g_sTag[client][0]        = '\0';
    g_sCustomName[client][0] = '\0';
    g_sSteamName[client][0]  = '\0';
    g_bSpawned[client]       = false;

    if (IsFakeClient(client))
        return;

    // Salva nome original do Steam
    GetClientName(client, g_sSteamName[client], MAX_NAME_LENGTH);

    if (g_hDB != null)
        DB_LoadPlayer(client);
}

public void OnClientDisconnect(int client)
{
    g_sTag[client][0]        = '\0';
    g_sCustomName[client][0] = '\0';
    g_sSteamName[client][0]  = '\0';
    g_bSpawned[client]       = false;
}

// ============================================================
// Evento spawn
// ============================================================
public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));

    if (client < 1 || client > MaxClients)
        return;

    if (!IsClientInGame(client) || IsFakeClient(client))
        return;

    // Reaplica nome+tag ao spawnar
    ApplyName(client);

    // Mensagem de boas-vindas só no primeiro spawn
    if (!g_bSpawned[client])
    {
        g_bSpawned[client] = true;
        CreateTimer(g_cvDelay.FloatValue, Timer_ShowWelcomeMsg, GetClientUserId(client));
    }
}

// ============================================================
// Monta e aplica o nome final: [tag] nome
// ============================================================
void ApplyName(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
        return;

    // Nome base: customizado ou Steam
    char sBaseName[MAX_NAME_LENGTH];
    if (g_sCustomName[client][0] != '\0')
        strcopy(sBaseName, sizeof(sBaseName), g_sCustomName[client]);
    else
        strcopy(sBaseName, sizeof(sBaseName), g_sSteamName[client]);

    // Nome final: [tag] nome  ou  somente nome
    char sFinalName[MAX_NAME_LENGTH];
    if (g_sTag[client][0] != '\0')
        Format(sFinalName, sizeof(sFinalName), "[%s] %s", g_sTag[client], sBaseName);
    else
        strcopy(sFinalName, sizeof(sFinalName), sBaseName);

    SetClientName(client, sFinalName);
}

// ============================================================
// Reaplica ao trocar/reiniciar capítulo
// ============================================================
public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
        g_bSpawned[i] = false;
}

// ============================================================
// Mensagem de boas-vindas
// ============================================================
public Action Timer_ShowWelcomeMsg(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Stop;

    char sLine1[128], sLine2[128], sLine3[128], sLine4[128];
    LoadMessageLines(sLine1, sLine2, sLine3, sLine4);

    DataPack dp = new DataPack();
    dp.WriteCell(userid);
    dp.WriteString(sLine1);
    dp.WriteString(sLine2);
    dp.WriteString(sLine3);
    dp.WriteString(sLine4);
    dp.WriteFloat(GetGameTime() + g_cvDuration.FloatValue);

    CreateTimer(0.1, Timer_RepeatMsg, dp, TIMER_REPEAT | TIMER_DATA_HNDL_CLOSE);

    return Plugin_Stop;
}

public Action Timer_RepeatMsg(Handle timer, DataPack dp)
{
    dp.Reset();
    int userid = dp.ReadCell();
    char sLine1[128]; dp.ReadString(sLine1, sizeof(sLine1));
    char sLine2[128]; dp.ReadString(sLine2, sizeof(sLine2));
    char sLine3[128]; dp.ReadString(sLine3, sizeof(sLine3));
    char sLine4[128]; dp.ReadString(sLine4, sizeof(sLine4));
    float fEndTime = dp.ReadFloat();

    if (GetGameTime() >= fEndTime)
        return Plugin_Stop;

    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Stop;

    PrintHintText(client, "%s\n%s\n%s\n%s", sLine1, sLine2, sLine3, sLine4);

    return Plugin_Continue;
}

void LoadMessageLines(char[] sLine1, char[] sLine2, char[] sLine3, char[] sLine4)
{
    char sPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sPath, sizeof(sPath), "configs/tags_mensagem.cfg");

    KeyValues kv = new KeyValues("mensagem");

    if (!kv.ImportFromFile(sPath))
    {
        strcopy(sLine1, 128, "Personalize seu nome! / Personaliza tu nombre!");
        strcopy(sLine2, 128, "!tag <texto> | !nome <texto>");
        strcopy(sLine3, 128, "!cleartag | !clearnome");
        strcopy(sLine4, 128, "");
        delete kv;
        return;
    }

    kv.GetString("linha1", sLine1, 128, "Personalize seu nome! / Personaliza tu nombre!");
    kv.GetString("linha2", sLine2, 128, "!tag <texto> | !nome <texto>");
    kv.GetString("linha3", sLine3, 128, "!cleartag | !clearnome");
    kv.GetString("linha4", sLine4, 128, "");

    delete kv;
}

// ============================================================
// Banco de dados — Carregar tag e nome
// ============================================================
void DB_LoadPlayer(int client)
{
    if (g_hDB == null || IsFakeClient(client))
        return;

    char sSteamID[32];
    if (!GetClientAuthId(client, AuthId_Steam2, sSteamID, sizeof(sSteamID)))
        return;

    char sQuery[256];
    Format(sQuery, sizeof(sQuery),
        "SELECT tag, custom_name FROM player_data WHERE steamid = '%s'", sSteamID);

    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(client));
    g_hDB.Query(DB_OnPlayerLoaded, sQuery, dp);
}

public void DB_OnPlayerLoaded(Database db, DBResultSet results, const char[] error, DataPack dp)
{
    dp.Reset();
    int userid = dp.ReadCell();
    delete dp;

    if (results == null)
    {
        LogError("[Tags] Erro ao carregar dados: %s", error);
        return;
    }

    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client))
        return;

    if (results.FetchRow())
    {
        results.FetchString(0, g_sTag[client],        MAX_TAG_LENGTH);
        results.FetchString(1, g_sCustomName[client], MAX_NAME_LENGTH);
        ApplyName(client);
    }
}

// ============================================================
// Banco de dados — Salvar
// ============================================================
void DB_SavePlayer(int client)
{
    if (g_hDB == null || IsFakeClient(client))
        return;

    char sSteamID[32];
    if (!GetClientAuthId(client, AuthId_Steam2, sSteamID, sizeof(sSteamID)))
        return;

    char sEscapedTag[MAX_TAG_LENGTH * 2];
    char sEscapedName[MAX_NAME_LENGTH * 2];
    g_hDB.Escape(g_sTag[client],        sEscapedTag,  sizeof(sEscapedTag));
    g_hDB.Escape(g_sCustomName[client], sEscapedName, sizeof(sEscapedName));

    char sQuery[512];
    Format(sQuery, sizeof(sQuery),
        "INSERT OR REPLACE INTO player_data (steamid, tag, custom_name) VALUES ('%s', '%s', '%s')",
        sSteamID, sEscapedTag, sEscapedName);

    g_hDB.Query(DB_OnSaved, sQuery);
}

public void DB_OnSaved(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
        LogError("[Tags] Erro ao salvar dados: %s", error);
}

// ============================================================
// Validação de tag
// ============================================================
bool IsTagAllowed(int client, const char[] sTag)
{
    if (CheckCommandAccess(client, "sm_settag", ADMFLAG_GENERIC))
        return true;

    for (int i = 0; i < sizeof(g_sReservedPrefixes); i++)
        if (strncmp(sTag, g_sReservedPrefixes[i], strlen(g_sReservedPrefixes[i])) == 0)
            return false;

    char sPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sPath, sizeof(sPath), "configs/tags_proibidas.cfg");

    KeyValues kv = new KeyValues("proibidas");
    if (kv.ImportFromFile(sPath) && kv.GotoFirstSubKey(false))
    {
        do
        {
            char sProibida[64];
            kv.GetString(NULL_STRING, sProibida, sizeof(sProibida));
            if (strlen(sProibida) > 0 && StrContains(sTag, sProibida, false) != -1)
            {
                delete kv;
                return false;
            }
        }
        while (kv.GotoNextKey(false));
    }
    delete kv;

    return true;
}

// ============================================================
// !tag <texto>
// ============================================================
public Action Cmd_SetTag(int client, int args)
{
    if (client == 0) { ReplyToCommand(client, "[Tags] Apenas jogadores."); return Plugin_Handled; }
    if (args < 1)    { PrintToChat(client, " \x04[Tags]\x01 Use: !tag <texto>"); return Plugin_Handled; }

    char sTag[MAX_TAG_LENGTH];
    GetCmdArg(1, sTag, sizeof(sTag));
    TrimString(sTag);

    if (strlen(sTag) == 0)      { PrintToChat(client, " \x04[Tags]\x01 Tag invalida.");                      return Plugin_Handled; }
    if (strlen(sTag) > 20)      { PrintToChat(client, " \x04[Tags]\x01 Maximo 20 caracteres.");              return Plugin_Handled; }
    if (!IsTagAllowed(client, sTag)) { PrintToChat(client, " \x04[Tags]\x01 Essa tag nao e permitida."); return Plugin_Handled; }

    strcopy(g_sTag[client], MAX_TAG_LENGTH, sTag);
    ApplyName(client);
    DB_SavePlayer(client);

    PrintToChat(client, " \x04[Tags]\x01 Tag definida: \x05[%s]", sTag);
    return Plugin_Handled;
}

// ============================================================
// !cleartag
// ============================================================
public Action Cmd_ClearTag(int client, int args)
{
    if (client == 0) { ReplyToCommand(client, "[Tags] Apenas jogadores."); return Plugin_Handled; }

    g_sTag[client][0] = '\0';
    ApplyName(client);
    DB_SavePlayer(client);

    PrintToChat(client, " \x04[Tags]\x01 Tag removida.");
    return Plugin_Handled;
}

// ============================================================
// !nome <texto>
// ============================================================
public Action Cmd_SetName(int client, int args)
{
    if (client == 0) { ReplyToCommand(client, "[Tags] Apenas jogadores."); return Plugin_Handled; }
    if (args < 1)    { PrintToChat(client, " \x04[Tags]\x01 Use: !nome <texto>"); return Plugin_Handled; }

    char sName[MAX_NAME_LENGTH];
    GetCmdArg(1, sName, sizeof(sName));
    TrimString(sName);

    if (strlen(sName) == 0)  { PrintToChat(client, " \x04[Tags]\x01 Nome invalido.");          return Plugin_Handled; }
    if (strlen(sName) > 32)  { PrintToChat(client, " \x04[Tags]\x01 Maximo 32 caracteres."); return Plugin_Handled; }

    strcopy(g_sCustomName[client], MAX_NAME_LENGTH, sName);
    ApplyName(client);
    DB_SavePlayer(client);

    PrintToChat(client, " \x04[Tags]\x01 Nome definido: \x05%s", sName);
    return Plugin_Handled;
}

// ============================================================
// !clearnome
// ============================================================
public Action Cmd_ClearName(int client, int args)
{
    if (client == 0) { ReplyToCommand(client, "[Tags] Apenas jogadores."); return Plugin_Handled; }

    g_sCustomName[client][0] = '\0';
    ApplyName(client);
    DB_SavePlayer(client);

    PrintToChat(client, " \x04[Tags]\x01 Nome customizado removido. Usando nome Steam.");
    return Plugin_Handled;
}

// ============================================================
// Admin: sm_settag <jogador> <tag>
// ============================================================
public Action Cmd_AdminSetTag(int client, int args)
{
    if (args < 2) { ReplyToCommand(client, "[Tags] Use: sm_settag <jogador> <tag>"); return Plugin_Handled; }

    char sTarget[64], sTag[MAX_TAG_LENGTH];
    GetCmdArg(1, sTarget, sizeof(sTarget));
    GetCmdArg(2, sTag,    sizeof(sTag));
    TrimString(sTag);

    int target = FindTarget(client, sTarget, true, false);
    if (target == -1) return Plugin_Handled;

    strcopy(g_sTag[target], MAX_TAG_LENGTH, sTag);
    ApplyName(target);
    DB_SavePlayer(target);

    ReplyToCommand(client, "[Tags] Tag de %N definida para [%s].", target, sTag);
    PrintToChat(target, " \x04[Tags]\x01 Um admin definiu sua tag para: \x05[%s]", sTag);
    return Plugin_Handled;
}

// ============================================================
// Admin: sm_cleartag_player <jogador>
// ============================================================
public Action Cmd_AdminClearTag(int client, int args)
{
    if (args < 1) { ReplyToCommand(client, "[Tags] Use: sm_cleartag_player <jogador>"); return Plugin_Handled; }

    char sTarget[64];
    GetCmdArg(1, sTarget, sizeof(sTarget));

    int target = FindTarget(client, sTarget, true, false);
    if (target == -1) return Plugin_Handled;

    g_sTag[target][0] = '\0';
    ApplyName(target);
    DB_SavePlayer(target);

    ReplyToCommand(client, "[Tags] Tag de %N removida.", target);
    PrintToChat(target, " \x04[Tags]\x01 Um admin removeu sua tag.");
    return Plugin_Handled;
}

// ============================================================
// Admin: sm_setnome <jogador> <nome>
// ============================================================
public Action Cmd_AdminSetName(int client, int args)
{
    if (args < 2) { ReplyToCommand(client, "[Tags] Use: sm_setnome <jogador> <nome>"); return Plugin_Handled; }

    char sTarget[64], sName[MAX_NAME_LENGTH];
    GetCmdArg(1, sTarget, sizeof(sTarget));
    GetCmdArg(2, sName,   sizeof(sName));
    TrimString(sName);

    int target = FindTarget(client, sTarget, true, false);
    if (target == -1) return Plugin_Handled;

    strcopy(g_sCustomName[target], MAX_NAME_LENGTH, sName);
    ApplyName(target);
    DB_SavePlayer(target);

    ReplyToCommand(client, "[Tags] Nome de %N definido para %s.", target, sName);
    PrintToChat(target, " \x04[Tags]\x01 Um admin definiu seu nome para: \x05%s", sName);
    return Plugin_Handled;
}

// ============================================================
// Admin: sm_clearnome_player <jogador>
// ============================================================
public Action Cmd_AdminClearName(int client, int args)
{
    if (args < 1) { ReplyToCommand(client, "[Tags] Use: sm_clearnome_player <jogador>"); return Plugin_Handled; }

    char sTarget[64];
    GetCmdArg(1, sTarget, sizeof(sTarget));

    int target = FindTarget(client, sTarget, true, false);
    if (target == -1) return Plugin_Handled;

    g_sCustomName[target][0] = '\0';
    ApplyName(target);
    DB_SavePlayer(target);

    ReplyToCommand(client, "[Tags] Nome customizado de %N removido.", target);
    PrintToChat(target, " \x04[Tags]\x01 Um admin removeu seu nome customizado.");
    return Plugin_Handled;
}
