#include <jni.h>
#include <string>
#include <vector>
#include "jlexa_speech_host.h"
#include "jlexa_backend_host.h"

static inline bool clearPendingException(JNIEnv* env) {
    if (env && env->ExceptionCheck()) {
        env->ExceptionDescribe();
        env->ExceptionClear();
        return true;
    }
    return false;
}

static jstring makeJavaStringFromUtf8(JNIEnv* env, const std::string& str) {
    if (str.empty()) {
        return env->NewStringUTF("");
    }
    jsize len = static_cast<jsize>(str.length());
    jbyteArray byteArray = env->NewByteArray(len);
    if (!byteArray) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        return env->NewStringUTF("");
    }

    env->SetByteArrayRegion(byteArray, 0, len, reinterpret_cast<const jbyte*>(str.data()));

    jclass stringClass = env->FindClass("java/lang/String");
    if (!stringClass) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        env->DeleteLocalRef(byteArray);
        return env->NewStringUTF("");
    }

    jstring charsetName = env->NewStringUTF("UTF-8");
    jmethodID stringConstructor = env->GetMethodID(stringClass, "<init>", "([BLjava/lang/String;)V");
    if (env->ExceptionCheck() || !stringConstructor) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        env->DeleteLocalRef(stringClass);
        if (charsetName) env->DeleteLocalRef(charsetName);
        env->DeleteLocalRef(byteArray);
        return env->NewStringUTF("");
    }

    jstring result = static_cast<jstring>(env->NewObject(stringClass, stringConstructor, byteArray, charsetName));
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        result = nullptr;
    }

    env->DeleteLocalRef(byteArray);
    if (charsetName) env->DeleteLocalRef(charsetName);
    env->DeleteLocalRef(stringClass);
    return result;
}

static std::string getStdUtf8FromJavaString(JNIEnv* env, jstring jstr) {
    if (!jstr) return "";
    
    jclass stringClass = env->GetObjectClass(jstr);
    if (!stringClass) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        return "";
    }
    jmethodID getBytesMethod = env->GetMethodID(stringClass, "getBytes", "(Ljava/lang/String;)[B");
    if (env->ExceptionCheck() || !getBytesMethod) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        env->DeleteLocalRef(stringClass);
        return "";
    }
    jstring charsetName = env->NewStringUTF("UTF-8");
    
    jbyteArray bytes = static_cast<jbyteArray>(env->CallObjectMethod(jstr, getBytesMethod, charsetName));
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        bytes = nullptr;
    }
    if (charsetName) env->DeleteLocalRef(charsetName);
    env->DeleteLocalRef(stringClass);
    
    if (!bytes) return "";
    
    jsize len = env->GetArrayLength(bytes);
    std::string result(len, '\0');
    env->GetByteArrayRegion(bytes, 0, len, reinterpret_cast<jbyte*>(&result[0]));
    env->DeleteLocalRef(bytes);
    
    return result;
}

extern "C" {

// ==========================================
// WHISPER JNI
// ==========================================

JNIEXPORT jboolean JNICALL
Java_com_example_local_1ai_1app_WhisperBridge_nativeLoadModel(
    JNIEnv* env,
    jobject /* this */,
    jstring model_path
) {
    if (!model_path) return JNI_FALSE;
    std::string path = getStdUtf8FromJavaString(env, model_path);
    bool result = JLexaSpeechHost::instance().loadModel(path);
    return result ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_example_local_1ai_1app_WhisperBridge_nativeUnloadModel(
    JNIEnv* /* env */,
    jobject /* this */
) {
    JLexaSpeechHost::instance().unloadModel();
}

JNIEXPORT jboolean JNICALL
Java_com_example_local_1ai_1app_WhisperBridge_nativeIsModelLoaded(
    JNIEnv* /* env */,
    jobject /* this */
) {
    return JLexaSpeechHost::instance().isModelLoaded() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jobject JNICALL
Java_com_example_local_1ai_1app_WhisperBridge_nativeTranscribe(
    JNIEnv* env,
    jobject /* this */,
    jfloatArray samples,
    jint sample_count,
    jint n_threads,
    jstring language,
    jobject progress_callback
) {
    if (!samples) return nullptr;

    jsize array_len = env->GetArrayLength(samples);
    jsize n_samples = (sample_count > 0 && sample_count <= array_len) ? static_cast<jsize>(sample_count) : array_len;
    jfloat* pcm_data = env->GetFloatArrayElements(samples, nullptr);
    if (!pcm_data) return nullptr;

    std::string lang = "en";
    if (language) {
        lang = getStdUtf8FromJavaString(env, language);
    }

    std::function<void(int)> progress_fn = nullptr;
    if (progress_callback) {
        jclass progressClass = env->GetObjectClass(progress_callback);
        if (progressClass) {
            jmethodID onProgressMethod = env->GetMethodID(progressClass, "onProgress", "(I)V");
            if (env->ExceptionCheck()) {
                env->ExceptionDescribe();
                env->ExceptionClear();
                onProgressMethod = nullptr;
            }
            if (onProgressMethod) {
                progress_fn = [env, progress_callback, onProgressMethod](int prog) {
                    env->CallVoidMethod(progress_callback, onProgressMethod, static_cast<jint>(prog));
                    if (env->ExceptionCheck()) {
                        env->ExceptionDescribe();
                        env->ExceptionClear();
                    }
                };
            }
        }
    }

    auto segments = JLexaSpeechHost::instance().transcribe(
        pcm_data,
        n_samples,
        n_threads,
        lang,
        progress_fn
    );

    env->ReleaseFloatArrayElements(samples, pcm_data, JNI_ABORT);

    const std::string inferenceError = JLexaSpeechHost::instance().getLastError();
    if (!inferenceError.empty()) {
        jclass exceptionClass = env->FindClass("java/lang/RuntimeException");
        if (exceptionClass && !env->ExceptionCheck()) {
            env->ThrowNew(exceptionClass, inferenceError.c_str());
        }
        if (exceptionClass) env->DeleteLocalRef(exceptionClass);
        return nullptr;
    }

    // Build Java List<Map<String, Object>>
    jclass arrayListClass = env->FindClass("java/util/ArrayList");
    if (!arrayListClass || clearPendingException(env)) return nullptr;
    jmethodID arrayListInit = env->GetMethodID(arrayListClass, "<init>", "()V");
    if (!arrayListInit || clearPendingException(env)) { env->DeleteLocalRef(arrayListClass); return nullptr; }
    jmethodID arrayListAdd = env->GetMethodID(arrayListClass, "add", "(Ljava/lang/Object;)Z");
    if (!arrayListAdd || clearPendingException(env)) { env->DeleteLocalRef(arrayListClass); return nullptr; }

    jclass hashMapClass = env->FindClass("java/util/HashMap");
    if (!hashMapClass || clearPendingException(env)) { env->DeleteLocalRef(arrayListClass); return nullptr; }
    jmethodID hashMapInit = env->GetMethodID(hashMapClass, "<init>", "()V");
    if (!hashMapInit || clearPendingException(env)) { env->DeleteLocalRef(arrayListClass); env->DeleteLocalRef(hashMapClass); return nullptr; }
    jmethodID hashMapPut = env->GetMethodID(hashMapClass, "put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
    if (!hashMapPut || clearPendingException(env)) { env->DeleteLocalRef(arrayListClass); env->DeleteLocalRef(hashMapClass); return nullptr; }

    jclass longClass = env->FindClass("java/lang/Long");
    if (!longClass || clearPendingException(env)) { env->DeleteLocalRef(arrayListClass); env->DeleteLocalRef(hashMapClass); return nullptr; }
    jmethodID longValueOf = env->GetStaticMethodID(longClass, "valueOf", "(J)Ljava/lang/Long;");
    if (!longValueOf || clearPendingException(env)) { env->DeleteLocalRef(arrayListClass); env->DeleteLocalRef(hashMapClass); env->DeleteLocalRef(longClass); return nullptr; }

    jclass doubleClass = env->FindClass("java/lang/Double");
    if (!doubleClass || clearPendingException(env)) { env->DeleteLocalRef(arrayListClass); env->DeleteLocalRef(hashMapClass); env->DeleteLocalRef(longClass); return nullptr; }
    jmethodID doubleValueOf = env->GetStaticMethodID(doubleClass, "valueOf", "(D)Ljava/lang/Double;");
    if (!doubleValueOf || clearPendingException(env)) { env->DeleteLocalRef(arrayListClass); env->DeleteLocalRef(hashMapClass); env->DeleteLocalRef(longClass); env->DeleteLocalRef(doubleClass); return nullptr; }

    jobject resultList = env->NewObject(arrayListClass, arrayListInit);
    if (!resultList || clearPendingException(env)) {
        env->DeleteLocalRef(arrayListClass);
        env->DeleteLocalRef(hashMapClass);
        env->DeleteLocalRef(longClass);
        env->DeleteLocalRef(doubleClass);
        return nullptr;
    }

    for (const auto& seg : segments) {
        if (env->PushLocalFrame(32) < 0) {
            clearPendingException(env);
            continue; // Out of memory
        }

        jobject segMap = env->NewObject(hashMapClass, hashMapInit);
        if (!segMap || clearPendingException(env)) {
            env->PopLocalFrame(nullptr);
            continue;
        }

        jstring kStart = env->NewStringUTF("start_ms");
        jobject vStart = env->CallStaticObjectMethod(longClass, longValueOf, (jlong)seg.start_ms);
        if (kStart && vStart && !clearPendingException(env)) {
            env->CallObjectMethod(segMap, hashMapPut, kStart, vStart);
            clearPendingException(env);
        }

        jstring kEnd = env->NewStringUTF("end_ms");
        jobject vEnd = env->CallStaticObjectMethod(longClass, longValueOf, (jlong)seg.end_ms);
        if (kEnd && vEnd && !clearPendingException(env)) {
            env->CallObjectMethod(segMap, hashMapPut, kEnd, vEnd);
            clearPendingException(env);
        }

        jstring kText = env->NewStringUTF("text");
        jstring vText = makeJavaStringFromUtf8(env, seg.text);
        if (kText && vText && !clearPendingException(env)) {
            env->CallObjectMethod(segMap, hashMapPut, kText, vText);
            clearPendingException(env);
        }

        jstring kConf = env->NewStringUTF("confidence");
        jobject vConf = env->CallStaticObjectMethod(doubleClass, doubleValueOf, (jdouble)seg.confidence);
        if (kConf && vConf && !clearPendingException(env)) {
            env->CallObjectMethod(segMap, hashMapPut, kConf, vConf);
            clearPendingException(env);
        }

        // Tokens
        jobject tokenList = env->NewObject(arrayListClass, arrayListInit);
        if (tokenList && !clearPendingException(env)) {
            for (const auto& tok : seg.tokens) {
                if (env->PushLocalFrame(16) < 0) {
                    clearPendingException(env);
                    continue;
                }

                jobject tokMap = env->NewObject(hashMapClass, hashMapInit);
                if (!tokMap || clearPendingException(env)) {
                    env->PopLocalFrame(nullptr);
                    continue;
                }

                jstring tkText = env->NewStringUTF("text");
                jstring tvText = makeJavaStringFromUtf8(env, tok.text);
                if (tkText && tvText && !clearPendingException(env)) {
                    env->CallObjectMethod(tokMap, hashMapPut, tkText, tvText);
                    clearPendingException(env);
                }

                jstring tkStart = env->NewStringUTF("start_ms");
                jobject tvStart = env->CallStaticObjectMethod(longClass, longValueOf, (jlong)tok.start_ms);
                if (tkStart && tvStart && !clearPendingException(env)) {
                    env->CallObjectMethod(tokMap, hashMapPut, tkStart, tvStart);
                    clearPendingException(env);
                }

                jstring tkEnd = env->NewStringUTF("end_ms");
                jobject tvEnd = env->CallStaticObjectMethod(longClass, longValueOf, (jlong)tok.end_ms);
                if (tkEnd && tvEnd && !clearPendingException(env)) {
                    env->CallObjectMethod(tokMap, hashMapPut, tkEnd, tvEnd);
                    clearPendingException(env);
                }

                jstring tkConf = env->NewStringUTF("confidence");
                jobject tvConf = env->CallStaticObjectMethod(doubleClass, doubleValueOf, (jdouble)tok.confidence);
                if (tkConf && tvConf && !clearPendingException(env)) {
                    env->CallObjectMethod(tokMap, hashMapPut, tkConf, tvConf);
                    clearPendingException(env);
                }

                env->CallBooleanMethod(tokenList, arrayListAdd, tokMap);
                clearPendingException(env);
                env->PopLocalFrame(nullptr);
            }

            jstring kTokens = env->NewStringUTF("tokens");
            if (kTokens && !clearPendingException(env)) {
                env->CallObjectMethod(segMap, hashMapPut, kTokens, tokenList);
                clearPendingException(env);
            }
        }

        env->CallBooleanMethod(resultList, arrayListAdd, segMap);
        clearPendingException(env);
        env->PopLocalFrame(nullptr);
    }

    env->DeleteLocalRef(arrayListClass);
    env->DeleteLocalRef(hashMapClass);
    env->DeleteLocalRef(longClass);
    env->DeleteLocalRef(doubleClass);
    return resultList;
}

JNIEXPORT void JNICALL
Java_com_example_local_1ai_1app_WhisperBridge_nativeCancel(
    JNIEnv* /* env */,
    jobject /* this */
) {
    JLexaSpeechHost::instance().cancel();
}

JNIEXPORT void JNICALL
Java_com_example_local_1ai_1app_WhisperBridge_nativeResetCancellation(
    JNIEnv* /* env */,
    jobject /* this */
) {
    JLexaSpeechHost::instance().resetCancellation();
}

// ==========================================
// LLAMA JNI
// ==========================================

JNIEXPORT jobject JNICALL
Java_com_example_local_1ai_1app_LlamaBridge_nativeGetAvailableBackends(
    JNIEnv* env,
    jobject /* this */
) {
    try {
    jclass arrayListClass = env->FindClass("java/util/ArrayList");
    if (!arrayListClass || clearPendingException(env)) return nullptr;
    jmethodID arrayListInit = env->GetMethodID(arrayListClass, "<init>", "()V");
    if (!arrayListInit || clearPendingException(env)) { env->DeleteLocalRef(arrayListClass); return nullptr; }
    jmethodID arrayListAdd = env->GetMethodID(arrayListClass, "add", "(Ljava/lang/Object;)Z");
    if (!arrayListAdd || clearPendingException(env)) { env->DeleteLocalRef(arrayListClass); return nullptr; }

    jclass hashMapClass = env->FindClass("java/util/HashMap");
    if (!hashMapClass || clearPendingException(env)) { env->DeleteLocalRef(arrayListClass); return nullptr; }
    jmethodID hashMapInit = env->GetMethodID(hashMapClass, "<init>", "()V");
    if (!hashMapInit || clearPendingException(env)) { env->DeleteLocalRef(arrayListClass); env->DeleteLocalRef(hashMapClass); return nullptr; }
    jmethodID hashMapPut = env->GetMethodID(hashMapClass, "put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
    if (!hashMapPut || clearPendingException(env)) { env->DeleteLocalRef(arrayListClass); env->DeleteLocalRef(hashMapClass); return nullptr; }

    jclass booleanClass = env->FindClass("java/lang/Boolean");
    if (!booleanClass || clearPendingException(env)) { env->DeleteLocalRef(arrayListClass); env->DeleteLocalRef(hashMapClass); return nullptr; }
    jmethodID booleanValueOf = env->GetStaticMethodID(booleanClass, "valueOf", "(Z)Ljava/lang/Boolean;");
    if (!booleanValueOf || clearPendingException(env)) { env->DeleteLocalRef(arrayListClass); env->DeleteLocalRef(hashMapClass); env->DeleteLocalRef(booleanClass); return nullptr; }

    jobject resultList = env->NewObject(arrayListClass, arrayListInit);
    if (!resultList || clearPendingException(env)) {
        env->DeleteLocalRef(arrayListClass);
        env->DeleteLocalRef(hashMapClass);
        env->DeleteLocalRef(booleanClass);
        return nullptr;
    }

    auto backends = JLexaBackendHost::instance().getAvailableBackends();
    for (const auto& b : backends) {
        if (env->PushLocalFrame(16) < 0) {
            clearPendingException(env);
            continue;
        }

        jobject bMap = env->NewObject(hashMapClass, hashMapInit);
        if (!bMap || clearPendingException(env)) {
            env->PopLocalFrame(nullptr);
            continue;
        }

        jstring kBackend = env->NewStringUTF("backend");
        jstring vBackend = makeJavaStringFromUtf8(env, b.backend);
        if (kBackend && vBackend && !clearPendingException(env)) {
            env->CallObjectMethod(bMap, hashMapPut, kBackend, vBackend);
            clearPendingException(env);
        }

        jstring kCompiled = env->NewStringUTF("compiled");
        jobject vCompiled = env->CallStaticObjectMethod(booleanClass, booleanValueOf, (jboolean)(b.compiled ? JNI_TRUE : JNI_FALSE));
        if (kCompiled && vCompiled && !clearPendingException(env)) {
            env->CallObjectMethod(bMap, hashMapPut, kCompiled, vCompiled);
            clearPendingException(env);
        }

        jstring kAvailable = env->NewStringUTF("available");
        jobject vAvailable = env->CallStaticObjectMethod(booleanClass, booleanValueOf, (jboolean)(b.available ? JNI_TRUE : JNI_FALSE));
        if (kAvailable && vAvailable && !clearPendingException(env)) {
            env->CallObjectMethod(bMap, hashMapPut, kAvailable, vAvailable);
            clearPendingException(env);
        }

        jstring kDevName = env->NewStringUTF("deviceName");
        jstring vDevName = makeJavaStringFromUtf8(env, b.deviceName);
        if (kDevName && vDevName && !clearPendingException(env)) {
            env->CallObjectMethod(bMap, hashMapPut, kDevName, vDevName);
            clearPendingException(env);
        }

        jstring kReason = env->NewStringUTF("reasonUnavailable");
        jstring vReason = makeJavaStringFromUtf8(env, b.reasonUnavailable);
        if (kReason && vReason && !clearPendingException(env)) {
            env->CallObjectMethod(bMap, hashMapPut, kReason, vReason);
            clearPendingException(env);
        }

        env->CallBooleanMethod(resultList, arrayListAdd, bMap);
        clearPendingException(env);
        env->PopLocalFrame(nullptr);
    }

    env->DeleteLocalRef(arrayListClass);
    env->DeleteLocalRef(hashMapClass);
    env->DeleteLocalRef(booleanClass);
    return resultList;

    } catch(const std::exception &e) {
        env->ThrowNew(env->FindClass("java/lang/RuntimeException"),e.what());
        return nullptr;
    }
}

JNIEXPORT jobject JNICALL
Java_com_example_local_1ai_1app_LlamaBridge_nativeGetActiveBackendInfo(
    JNIEnv* env,
    jobject /* this */
) {
    try {
    jclass hashMapClass = env->FindClass("java/util/HashMap");
    if (!hashMapClass || clearPendingException(env)) return nullptr;
    jmethodID hashMapInit = env->GetMethodID(hashMapClass, "<init>", "()V");
    if (!hashMapInit || clearPendingException(env)) { env->DeleteLocalRef(hashMapClass); return nullptr; }
    jmethodID hashMapPut = env->GetMethodID(hashMapClass, "put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
    if (!hashMapPut || clearPendingException(env)) { env->DeleteLocalRef(hashMapClass); return nullptr; }

    jclass integerClass = env->FindClass("java/lang/Integer");
    if (!integerClass || clearPendingException(env)) { env->DeleteLocalRef(hashMapClass); return nullptr; }
    jmethodID integerValueOf = env->GetStaticMethodID(integerClass, "valueOf", "(I)Ljava/lang/Integer;");
    if (!integerValueOf || clearPendingException(env)) { env->DeleteLocalRef(hashMapClass); env->DeleteLocalRef(integerClass); return nullptr; }

    auto info = JLexaBackendHost::instance().getActiveBackendInfo();
    jobject infoMap = env->NewObject(hashMapClass, hashMapInit);
    if (!infoMap || clearPendingException(env)) {
        env->DeleteLocalRef(hashMapClass);
        env->DeleteLocalRef(integerClass);
        return nullptr;
    }

    auto putString = [&](const char* key, const std::string& val) {
        jstring k = env->NewStringUTF(key);
        jstring v = makeJavaStringFromUtf8(env, val);
        if (k && v && !clearPendingException(env)) {
            env->CallObjectMethod(infoMap, hashMapPut, k, v);
            clearPendingException(env);
        }
    };

    auto putInt = [&](const char* key, int val) {
        jstring k = env->NewStringUTF(key);
        jobject v = env->CallStaticObjectMethod(integerClass, integerValueOf, (jint)val);
        if (k && v && !clearPendingException(env)) {
            env->CallObjectMethod(infoMap, hashMapPut, k, v);
            clearPendingException(env);
        }
    };

    putString("backend", info.backend);
    putString("deviceName", info.deviceName);
    putInt("gpuLayers", info.gpuLayers);
    putInt("contextLength", info.contextLength);
    putInt("threads", info.threads);
    putInt("batchSize", info.batchSize);
    putInt("ubatchSize", info.ubatchSize);
    putInt("flashAttention", info.flashAttention);

    env->DeleteLocalRef(hashMapClass);
    env->DeleteLocalRef(integerClass);
    return infoMap;

    } catch(const std::exception &e) {
        env->ThrowNew(env->FindClass("java/lang/RuntimeException"),e.what());
        return nullptr;
    }
}

JNIEXPORT jboolean JNICALL
Java_com_example_local_1ai_1app_LlamaBridge_nativeLoadModel(
    JNIEnv* env,
    jobject /* this */,
    jstring model_path,
    jstring backend,
    jint context_length,
    jint threads,
    jint gpu_layers,
    jint batch_size,
    jint ubatch_size,
    jint flash_attn
) {
    try {
    if (!model_path) return JNI_FALSE;
    std::string path = getStdUtf8FromJavaString(env, model_path);

    JLexaLlamaRuntimeConfig cfg;
    if (backend) {
        cfg.backend = getStdUtf8FromJavaString(env, backend);
    }
    cfg.contextLength = context_length;
    cfg.n_threads = threads;
    cfg.gpuLayers = gpu_layers;
    cfg.batchSize = batch_size;
    cfg.ubatchSize = ubatch_size;
    cfg.flashAttention = flash_attn;

    bool result = JLexaBackendHost::instance().loadModel(path, cfg);
    return result ? JNI_TRUE : JNI_FALSE;

    } catch(const std::exception &e) {
        env->ThrowNew(env->FindClass("java/lang/RuntimeException"),e.what());
        return JNI_FALSE;
    }
}

JNIEXPORT void JNICALL
Java_com_example_local_1ai_1app_LlamaBridge_nativeUnloadModel(
    JNIEnv* env,
    jobject /* this */
) {
    try {
    JLexaBackendHost::instance().unloadModel();

    } catch(const std::exception &e) {
        env->ThrowNew(env->FindClass("java/lang/RuntimeException"),e.what());
        return;
    }
}

JNIEXPORT jboolean JNICALL
Java_com_example_local_1ai_1app_LlamaBridge_nativeIsModelLoaded(
    JNIEnv* env,
    jobject /* this */
) {
    try {
    return JLexaBackendHost::instance().isModelLoaded() ? JNI_TRUE : JNI_FALSE;

    } catch(const std::exception &e) {
        env->ThrowNew(env->FindClass("java/lang/RuntimeException"),e.what());
        return JNI_FALSE;
    }
}

JNIEXPORT void JNICALL
Java_com_example_local_1ai_1app_LlamaBridge_nativeGenerate(
    JNIEnv* env,
    jobject /* this */,
    jstring prompt,
    jint max_tokens,
    jfloat temperature,
    jfloat top_p,
    jint seed,
    jobjectArray chat_roles,
    jobjectArray chat_contents,
    jobject callback
) {
    try {
    if (!callback) return;

    std::string prompt_str = "";
    if (prompt) {
        prompt_str = getStdUtf8FromJavaString(env, prompt);
    }

    std::vector<JLexaChatMessage> messages;
    if (chat_roles && chat_contents) {
        jsize n_roles = env->GetArrayLength(chat_roles);
        jsize n_contents = env->GetArrayLength(chat_contents);
        jsize count = n_roles < n_contents ? n_roles : n_contents;
        for (jsize i = 0; i < count; ++i) {
            jstring rStr = static_cast<jstring>(env->GetObjectArrayElement(chat_roles, i));
            clearPendingException(env);
            jstring cStr = static_cast<jstring>(env->GetObjectArrayElement(chat_contents, i));
            clearPendingException(env);
            std::string r = "user";
            std::string c = "";
            if (rStr) {
                r = getStdUtf8FromJavaString(env, rStr);
                env->DeleteLocalRef(rStr);
            }
            if (cStr) {
                c = getStdUtf8FromJavaString(env, cStr);
                env->DeleteLocalRef(cStr);
            }
            messages.push_back({r, c});
        }
    }

    jclass callbackClass = env->GetObjectClass(callback);
    jmethodID onTokenMethod = nullptr;
    jmethodID onCompleteMethod = nullptr;
    if (callbackClass) {
        onTokenMethod = env->GetMethodID(callbackClass, "onToken", "(Ljava/lang/String;)V");
        if (env->ExceptionCheck()) {
            env->ExceptionDescribe();
            env->ExceptionClear();
            onTokenMethod = nullptr;
        }
        onCompleteMethod = env->GetMethodID(callbackClass, "onComplete", "(ZLjava/lang/String;)V");
        if (env->ExceptionCheck()) {
            env->ExceptionDescribe();
            env->ExceptionClear();
            onCompleteMethod = nullptr;
        }
    }

    JLexaBackendHost::instance().generate(
        prompt_str,
        max_tokens,
        temperature,
        top_p,
        static_cast<uint32_t>(seed),
        messages,
        [env, callback, onTokenMethod](const std::string& token) {
            if (!onTokenMethod) return;
            if (env->PushLocalFrame(16) < 0) return;
            jstring jtoken = makeJavaStringFromUtf8(env, token);
            if (jtoken) {
                env->CallVoidMethod(callback, onTokenMethod, jtoken);
                if (env->ExceptionCheck()) {
                    env->ExceptionDescribe();
                    env->ExceptionClear();
                }
            }
            env->PopLocalFrame(nullptr);
        },
        [env, callback, onCompleteMethod](bool cancelled, const std::string& errorMsg) {
            if (!onCompleteMethod) return;
            if (env->PushLocalFrame(16) < 0) return;
            jstring jerr = makeJavaStringFromUtf8(env, errorMsg);
            env->CallVoidMethod(callback, onCompleteMethod, (jboolean)(cancelled ? JNI_TRUE : JNI_FALSE), jerr);
            if (env->ExceptionCheck()) {
                env->ExceptionDescribe();
                env->ExceptionClear();
            }
            env->PopLocalFrame(nullptr);
        }
    );

    } catch(const std::exception &e) {
        env->ThrowNew(env->FindClass("java/lang/RuntimeException"),e.what());
        return;
    }
}

JNIEXPORT void JNICALL
Java_com_example_local_1ai_1app_LlamaBridge_nativeCancel(
    JNIEnv* env,
    jobject /* this */
) {
    try {
    JLexaBackendHost::instance().cancel();

    } catch(const std::exception &e) {
        env->ThrowNew(env->FindClass("java/lang/RuntimeException"),e.what());
        return;
    }
}

JNIEXPORT void JNICALL
Java_com_example_local_1ai_1app_LlamaBridge_nativeResetCancellation(
    JNIEnv* env,
    jobject /* this */
) {
    try {
    JLexaBackendHost::instance().resetCancellation();

    } catch(const std::exception &e) {
        env->ThrowNew(env->FindClass("java/lang/RuntimeException"),e.what());
        return;
    }
}


JNIEXPORT jobject JNICALL
Java_com_example_local_1ai_1app_BackendPlugins_nativeDevices(JNIEnv *env, jobject self) {
    return Java_com_example_local_1ai_1app_LlamaBridge_nativeGetAvailableBackends(env, self);
}

JNIEXPORT jobjectArray JNICALL
Java_com_example_local_1ai_1app_BackendPlugins_nativeSelect(JNIEnv *env,jobject,jstring path) {
    try {
        JLexaBackendHost::instance().select(getStdUtf8FromJavaString(env,path));
        auto info=JLexaBackendHost::instance().pluginInfo();
        jobjectArray result=env->NewObjectArray(4,env->FindClass("java/lang/String"),nullptr);
        for(int i=0;i<4;i++) env->SetObjectArrayElement(result,i,makeJavaStringFromUtf8(env,info[i]));
        return result;
    } catch(const std::exception &e) {
        env->ThrowNew(env->FindClass("java/lang/RuntimeException"),e.what());return nullptr;
    }
}

JNIEXPORT jobjectArray JNICALL
Java_com_example_local_1ai_1app_BackendPlugins_nativeSelectSpeech(JNIEnv *env,jobject,jstring path) {
    try {
        JLexaSpeechHost::instance().select(getStdUtf8FromJavaString(env,path));
        auto info=JLexaSpeechHost::instance().pluginInfo();
        jobjectArray result=env->NewObjectArray(4,env->FindClass("java/lang/String"),nullptr);
        for(int i=0;i<4;i++) env->SetObjectArrayElement(result,i,makeJavaStringFromUtf8(env,info[i]));
        return result;
    } catch(const std::exception &e) {
        env->ThrowNew(env->FindClass("java/lang/RuntimeException"),e.what());return nullptr;
    }
}


JNIEXPORT jboolean JNICALL
Java_com_example_local_1ai_1app_LlamaBridge_nativeSupportsBenchmark(JNIEnv *env, jobject) {
    try { return JLexaBackendHost::instance().supportsBenchmark(); }
    catch (const std::exception &e) { env->ThrowNew(env->FindClass("java/lang/RuntimeException"), e.what()); return false; }
}
JNIEXPORT jlongArray JNICALL
Java_com_example_local_1ai_1app_LlamaBridge_nativeBenchmark(JNIEnv *env, jobject, jobject callback) {
    try {
        jclass cls = env->GetObjectClass(callback);
        jmethodID progress = env->GetMethodID(cls, "onProgress", "(ILjava/lang/String;JJJJ)V");
        if (clearPendingException(env) || !progress) {
            env->ThrowNew(env->FindClass("java/lang/RuntimeException"), "Benchmark callback unavailable"); return nullptr;
        }
        jlexa_benchmark_result stats{};
        int result = JLexaBackendHost::instance().benchmark(stats,
            [env, callback, progress](uint32_t phase, const std::string &text, const jlexa_benchmark_result &s) {
                if (env->PushLocalFrame(8) < 0) return;
                jstring value = makeJavaStringFromUtf8(env, text);
                env->CallVoidMethod(callback, progress, (jint)phase, value,
                    (jlong)s.prompt_tokens, (jlong)s.generated_tokens, (jlong)s.prefill_us, (jlong)s.decode_us);
                clearPendingException(env); env->PopLocalFrame(nullptr);
            });
        jlong values[] = {(jlong)stats.source_tokens,(jlong)stats.prompt_tokens,(jlong)stats.generated_tokens,
            (jlong)stats.decoded_tokens,(jlong)stats.prefill_us,(jlong)stats.decode_us,(jlong)result};
        jlongArray output = env->NewLongArray(7);
        env->SetLongArrayRegion(output, 0, 7, values);
        return output;
    } catch (const std::exception &e) {
        env->ThrowNew(env->FindClass("java/lang/RuntimeException"), e.what()); return nullptr;
    }
}

} // extern "C"
