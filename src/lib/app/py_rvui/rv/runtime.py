#
# Copyright (C) 2023  Autodesk, Inc. All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
import os


def __dummy__():
    pass


# QWebEngineProfile.defaultProfile() initialises Chromium (about a second on the main
# thread, plus the QtWebEngineProcess children), so nothing is imported or scheduled at
# module import time: Chromium only starts when the first web view is created. Code that
# creates a QWebEngineView/QWebEnginePage calls this right before doing so, so that the
# profile user agent carries the " RV/<version>" suffix.
_web_profile_ready = False


def setup_webview_default_profile():
    global _web_profile_ready
    if _web_profile_ready:
        return
    try:
        from PySide2.QtWebEngineWidgets import QWebEngineProfile
    except ImportError:
        try:
            from PySide6.QtWebEngineCore import QWebEngineProfile
        except ImportError:
            return

    _web_profile_ready = True
    default_profile = QWebEngineProfile.defaultProfile()
    user_agent = default_profile.httpUserAgent() + " RV/" + os.environ["TWK_APP_VERSION"]
    default_profile.setHttpUserAgent(user_agent)
