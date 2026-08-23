//
//  MAAError.swift
//  MAA
//
//  Created by hguandl on 30/4/2023.
//

import Foundation

enum MAAError: Error, LocalizedError {
    case emptyItemObject
    case gameStartFailed
    case handleNotRunning
    case imageUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyItemObject:
            return "任务参数为空"
        case .gameStartFailed:
            return "游戏启动失败"
        case .handleNotRunning:
            return "MAA 核心忙碌或未能进入就绪状态，请稍后重试"
        case .imageUnavailable:
            return "无法获取屏幕截图，请检查模拟器连接与屏幕录制权限"
        }
    }
}
