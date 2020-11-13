//
//  CoumpoundValue.swift
//  HaishinKit
//
//  Created by Guy on 13.11.20.
//  Copyright © 2020 Sporfie. All rights reserved.
//

import Foundation

open class CoumpoundValue<T: Numeric> {
	open var values = [T]()
	open var total: T {
		return values.reduce(0) { (current: T, value: T) -> T in
			return current + value
		}
	}
	open func add(_ value: T, trim: Int) {
		values.append(value)
		while values.count > trim {
			values.remove(at: 0)
		}
	}
}
