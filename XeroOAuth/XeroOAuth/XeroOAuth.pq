// This file contains your Data Connector logic
section XeroOAuth;

// Refer to https://developer.xero.com/documentation/oauth2/pkce-flow

//
// OAuth configuration settings
//
// client_id = Text.FromBinary(Extension.Contents("client_id"));
// client_secret = Text.FromBinary(Extension.Contents("client_secret"));
client_id = "YOUR_CLIENT_ID";
client_secret = "YOUR_CLIENT_SECRET";
code_challenge = "YOUR_CODE_CHALLENGE";
code_challenge_method = "S256";
response_type = "code";
scope = "workflowmax, offline_access";
redirect_uri = "https://oauth.powerbi.com/views/oauthredirect.html";
code_verifier = "YOUR_CODE_VERIFIER";
grant_type = "authorization_code";

//
// Constants
//
windowWidth = 1200;
windowHeight = 1000;

//
// Exported functions
//
// These functions are exported to the M Engine (making them visible to end users), and associates
// them with the specified Data Source Kind. The Data Source Kind is used when determining which
// credentials to use during evaluation. Credential matching is done based on the function's parameters.
// All data source functions associated to the same Data Source Kind must have a matching set of required
// function parameters, including type, name, and the order in which they appear.
[DataSource.Kind="XeroOAuth", Publish="XeroOAuth.Publish"]
shared XeroOAuth.Contents = Value.ReplaceType(Github.Contents, type function (url as Uri.Type) as any);

[DataSource.Kind="XeroOAuth"]
shared XeroOAuth.PagedTable = Value.ReplaceType(Github.PagedTable, type function (url as Uri.Type) as nullable table);

//
// Data Source definition
//
XeroOAuth = [
    Authentication = [
        OAuth = [
            StartLogin = StartLogin,
            FinishLogin = FinishLogin
        ]
    ],
    Label = Extension.LoadString("DataSourceLabel")
];

// Data Source UI publishing description
XeroOAuth.Publish = [
    Beta = true,
    Category = "Other",
    ButtonText = { Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp") },
    LearnMoreUrl = "https://powerbi.microsoft.com/",
    SourceImage = XeroOAuth.Icons,
    SourceTypeImage = XeroOAuth.Icons
];

XeroOAuth.Icons = [
    Icon16 = { Extension.Contents("XeroOAuth16.png"), Extension.Contents("XeroOAuth20.png"), Extension.Contents("XeroOAuth24.png"), Extension.Contents("XeroOAuth32.png") },
    Icon32 = { Extension.Contents("XeroOAuth32.png"), Extension.Contents("XeroOAuth40.png"), Extension.Contents("XeroOAuth48.png"), Extension.Contents("XeroOAuth64.png") }
];

//
// Github.Contents - retrieves a single page of data from github and sets a
// Next link value as meta on the returned json response. We parse the json
// result (which will be a list of records) into a table.
//
Github.Contents = (url as text) =>
    let
        content = Web.Contents(url),
        link = GetNextLink(content),
        json = Json.Document(content),
        table = Table.FromList(json, Splitter.SplitByNothing())
    in
        table meta [Next=link];

Github.PagedTable = (url as text) => Table.GenerateByPage((previous) =>
    let
        // If we have a previous page, get its Next link from metadata on the page.
        next = if (previous <> null) then Value.Metadata(previous)[Next] else null,
        // If we have a next link, use it, otherwise use the original URL that was passed in.
        urlToUse = if (next <> null) then next else url,
        // If we have a previous page, but don't have a next link, then we're done paging.
        // Otherwise retrieve the next page.
        current = if (previous <> null and next = null) then null else Github.Contents(urlToUse),
        // If we got data back from the current page, get the link for the next page
        link = if (current <> null) then Value.Metadata(current)[Next] else null
    in
        current meta [Next=link]);

// This function returns an absolute URL to the next page of data.
//
// The 'response' parameter typically contains the result of the call to Web.Contents.
// The 'request' parameter is optional and contains values to formulate the request.
// It is typically used when the next link is a relative URL and needs to be
// appended to a base URL from the request. Its format is up to the extension author.
//
// The current implementation is specific to Github, which returns its next link
// in a "Link" header in the response. The 'request' parameter is not used.
// You will most likely need to replace the logic below with whatever paging
// mechanism is used by your data source.
//
GetNextLink = (response, optional request) =>
    let
        // extract the "Link" header if it exists
        link = Value.Metadata(response)[Headers][#"Link"]?,
        links = Text.Split(link, ","),
        splitLinks = List.Transform(links, each Text.Split(Text.Trim(_), ";")),
        next = List.Select(splitLinks, each Text.Trim(_{1}) = "rel=""next"""),
        first = List.First(next),
        removedBrackets = Text.Range(first{0}, 1, Text.Length(first{0}) - 2)
    in
        try removedBrackets otherwise null;

//
// Common code
//

// Calls the getNextPage function until it returns null.
// Each call to getNextPage expects a table of data to be returned.
// The result of the previous call to getNextPage is passed along to the next call.
// Appends all pages (tables) together into a single result.
// Returns an empty table if the first call to getNextPage returns null.
Table.GenerateByPage = (getNextPage as function) as table =>
    let
        listOfPages = List.Generate(
            () => getNextPage(null),
            (lastPage) => lastPage <> null,
            (lastPage) => getNextPage(lastPage)
        ),
        tableOfPages = Table.FromList(listOfPages, Splitter.SplitByNothing(), {"Column1"}),
        firstRow = tableOfPages{0}?
    in
        if (firstRow = null) then
            Table.FromRows({})
        else
            Value.ReplaceType(
                Table.ExpandTableColumn(tableOfPages, "Column1", Table.ColumnNames(firstRow[Column1])),
                Value.Type(firstRow[Column1])
            );


//
// OAuth2 flow definition
//
StartLogin = (resourceUrl, state, display) =>
    let
        AuthorizeUrl = "https://login.xero.com/identity/connect/authorize?" & Uri.BuildQueryString([
            response_type = response_type,
            client_id = client_id,
            scope = scope,
            state = state,
            // OR state = "UEw50EgwEiIPUXs8",
            code_challenge = code_challenge,
            code_challenge_method = code_challenge_method,
            redirect_uri = redirect_uri
        ])
    in
        [
            LoginUri = AuthorizeUrl,
            CallbackUri = redirect_uri,
            WindowHeight = windowHeight,
            WindowWidth = windowWidth,
            Context = null
        ];

FinishLogin = (context, callbackUri, state) =>
    let
        Parts = Uri.Parts(callbackUri)[Query]
    in
        TokenMethod(Parts[code]);

TokenMethod = (code) =>
    let
        Response = Web.Contents("https://identity.xero.com/connect/token", [
            Content = Text.ToBinary(Uri.BuildQueryString([
                grant_type = grant_type,
                client_id = client_id,
                code = code,
                redirect_uri = redirect_uri,
                code_verifier = code_verifier
            ])),
            Headers=[#"Content-type" = "application/x-www-form-urlencoded",#"Accept" = "application/json"]]),
        Parts = Json.Document(Response)
    in
        Parts;
