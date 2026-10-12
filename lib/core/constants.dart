/// Shared limits and thresholds from the SPEC.
const int rulesLimit = 6000;
const int notesLimit = 8000;
const int historyVersionsKept = 20;

const int chatHistoryMaxMessages = 30;
const int chatHistoryMaxChars = 12000;
const int conversationTitleLength = 40;

const int targetWordsMax = 40;
const int recentlyKnownMax = 50;

const int wordJudgeMessageWindow = 4;
const Duration wordJudgeMinReviewGap = Duration(minutes: 30);

const Duration tapAgainMinGap = Duration(hours: 24);

const int notesUnprocessedThreshold = 8;
const int notesUnprocessedThresholdOnLeave = 2;
const int notesMaxMessagesPerCall = 40;
const int notesMaxCallsPerRun = 3;
const double notesTargetRatio = 0.8;
const double notesRetryRatio = 0.6;

const int youngStabilityThresholdDays = 21;

const int llmMaxRetries = 2;
const Duration llmRetryDelayFirst = Duration(seconds: 1);
const Duration llmRetryDelaySecond = Duration(seconds: 3);

/// HTTP timeouts for LLM requests (A-12): a stalled connection must fail
/// instead of hanging the app (a stuck `complete` would keep the tutor
/// scheduler "running" forever). Receive allows slow first tokens from
/// local servers; the overall cap bounds trickling non-streaming bodies.
const Duration llmConnectTimeout = Duration(seconds: 15);
const Duration llmSendTimeout = Duration(seconds: 30);
const Duration llmReceiveTimeout = Duration(seconds: 60);
const Duration llmCompleteTimeout = Duration(seconds: 120);

const int updateRulesMaxRounds = 2;
