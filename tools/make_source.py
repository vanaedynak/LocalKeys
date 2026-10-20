"""Builds the SideStore/AltStore source so the iPad app can be updated from inside SideStore.
Usage: make_source.py <dist dir> <owner/repo> <tag> <version> <build>"""
import datetime
import json
import os
import sys

dist, repo, tag, version, build = sys.argv[1:6]
ipa = os.path.join(dist, "LocalKeys.ipa")

source = {
    "name": "LocalKeys",
    "identifier": "com.localkeys.source",
    "subtitle": "iPad как клавиатура и тачпад для Windows",
    "website": f"https://github.com/{repo}",
    "iconURL": f"https://raw.githubusercontent.com/{repo}/main/docs/icon.png",
    "apps": [
        {
            "name": "LocalKeys",
            "bundleIdentifier": "com.localkeys.app",
            "developerName": "LocalKeys",
            "subtitle": "Клавиатура, тачпад и игровые раскладки",
            "localizedDescription": (
                "Превращает iPad в полноценную клавиатуру и тачпад для компьютера с Windows: "
                "мультитач, одновременные нажатия, игровые раскладки, Wi-Fi и USB-C."
            ),
            "iconURL": f"https://raw.githubusercontent.com/{repo}/main/docs/icon.png",
            "tintColor": "5E81FF",
            "category": "utilities",
            "versions": [
                {
                    "version": version,
                    "buildVersion": build,
                    "date": datetime.date.today().isoformat(),
                    "localizedDescription": f"LocalKeys {version}",
                    "downloadURL": f"https://github.com/{repo}/releases/download/{tag}/LocalKeys.ipa",
                    "size": os.path.getsize(ipa),
                    "minOSVersion": "16.0",
                }
            ],
            "appPermissions": {
                "entitlements": [],
                "privacy": {
                    "NSLocalNetworkUsageDescription": "Поиск компьютера в локальной сети и передача нажатий."
                },
            },
        }
    ],
    "news": [],
}

with open(os.path.join(dist, "sidestore-source.json"), "w", encoding="utf-8") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)
print("source written")
