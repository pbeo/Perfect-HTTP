//
//  StaticFileHandler.swift
//  PerfectLib
//
//  Created by Kyle Jessup on 2016-01-06.
//  Copyright © 2016 PerfectlySoft. All rights reserved.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2016 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

import PerfectLib

#if os(OSX)
	import Foundation
	
	extension String {
		var pathExtension: String {
			let url = URL(fileURLWithPath: self)
			return url.pathExtension ?? ""
		}
	}
#endif

import OpenSSL

extension String.UTF8View {
	var sha1: [UInt8] {
		let bytes = UnsafeMutablePointer<UInt8>(allocatingCapacity:  Int(SHA_DIGEST_LENGTH))
		defer { bytes.deallocateCapacity(Int(SHA_DIGEST_LENGTH)) }
		
		SHA1(Array<UInt8>(self), (self.count), bytes)
		
		var r = [UInt8]()
		for idx in 0..<Int(SHA_DIGEST_LENGTH) {
			r.append(bytes[idx])
		}
		return r
	}
}

extension UInt8 {
	// same as String(self, radix: 16)
	// but outputs two characters. i.e. 0 padded
	var hexString: String {
		let s = String(self, radix: 16)
		if s.characters.count == 1 {
			return "0" + s
		}
		return s
	}
}

/// A web request handler which can be used to return static disk-based files to the client.
/// Supports byte ranges, ETags and streaming very large files.
public struct StaticFileHandler {
	
	let chunkedBufferSize = 1024*200
	
    /// Public initializer
	public init() {}
	
    /// Main entry point. A registered URL handler should call this and pass the request and response objects.
    /// After calling this, the StaticFileHandler owns the request and will handle it until completion.
	public func handleRequest(request req: HTTPRequest, response: HTTPResponse) {
        var path = req.path
		if path[path.index(before: path.endIndex)] == "/" {
			path.append("index.html") // !FIX! needs to be configurable
		}
		let documentRoot = req.documentRoot
		let file = File(documentRoot + "/" + path)
        
        func fnf(msg: String) {
            response.status = .notFound
            response.appendBody(string: msg)
            // !FIX! need 404.html or some such thing
            response.completed()
        }
        
		guard file.exists else {
            return fnf(msg: "The file \(path) was not found.")
		}
        do {
            try file.open(.read)
            self.sendFile(request: req, response: response, file: file)
        } catch {
            return fnf(msg: "The file \(path) could not be opened \(error).")
        }
	}
	
	func sendFile(request req: HTTPRequest, response resp: HTTPResponse, file: File) {
		
		resp.addHeader(.acceptRanges, value: "bytes")

		if let rangeRequest = req.header(.range) {
            return self.performRangeRequest(rangeRequest: rangeRequest, request: req, response: resp, file: file)
        } else if let ifNoneMatch = req.header(.ifNoneMatch) {
            let eTag = self.getETag(file: file)
            if ifNoneMatch == eTag {
                resp.status = .notModified
                return resp.completed()
            }
        }
        
        let size = file.size
        let contentType = MimeType.forExtension(file.path.pathExtension)
        
		resp.status = .ok
		resp.addHeader(.contentType, value: contentType)
		resp.addHeader(.contentLength, value: "\(size)")
        
        self.addETag(response: resp, file: file)
        
		if case .head = req.method {
			return resp.completed()
		}
		
		self.sendFile(remainingBytes: size, response: resp, file: file) {
			ok in
			file.close()
			resp.completed()
		}
	}
	
    func performRangeRequest(rangeRequest: String, request: HTTPRequest, response: HTTPResponse, file: File) {
        let size = file.size
        let ranges = self.parseRangeHeader(fromHeader: rangeRequest, max: size)
        if ranges.count == 1 {
            let range = ranges[0]
            let rangeCount = range.count
            let contentType = MimeType.forExtension(file.path.pathExtension)
            
            response.status = .partialContent
            response.addHeader(.contentLength, value: "\(rangeCount)")
            response.addHeader(.contentType, value: contentType)
            response.addHeader(.contentRange, value: "bytes \(range.lowerBound)-\(range.upperBound-1)/\(size)")
            
            if case .head = request.method {
                return response.completed()
            }
            
            file.marker = range.lowerBound
            
            return self.sendFile(remainingBytes: rangeCount, response: response, file: file) {
                ok in
                
                file.close()
                response.completed()
            }
        } else if ranges.count > 0 {
            // !FIX! support multiple ranges
            response.status = .internalServerError
            return response.completed()
        }
    }
    
    func getETag(file f: File) -> String {
        let eTagStr = f.path + "\(f.modificationTime)"
        let eTag = eTagStr.utf8.sha1
        let eTagReStr = eTag.map { $0.hexString }.joined(separator: "")
        
        return eTagReStr
    }
    
    func addETag(response resp: HTTPResponse, file: File) {
        let eTag = self.getETag(file: file)
        resp.addHeader(.eTag, value: eTag)
    }
    
	func sendFile(remainingBytes remaining: Int, response: HTTPResponse, file: File, completion: (Bool) -> ()) {
		
		let thisRead = min(chunkedBufferSize, remaining)
		do {
			let bytes = try file.readSomeBytes(count: thisRead)
			response.appendBody(bytes: bytes)
			response.push {
				ok in
				
				if !ok || thisRead == remaining {
					// done
					completion(ok)
				} else {
					self.sendFile(remainingBytes: remaining - bytes.count, response: response, file: file, completion: completion)
				}
			}
		} catch {
			completion(false)
		}
	}
	
	// bytes=0-3/7-9/10-15
	func parseRangeHeader(fromHeader header: String, max: Int) -> [Range<Int>] {
		let initialSplit = header.characters.split(separator: "=")
		guard initialSplit.count == 2 && String(initialSplit[0]) == "bytes" else {
			return [Range<Int>]()
		}
		
		let ranges = initialSplit[1]
		return ranges.split(separator: "/").flatMap { self.parseOneRange(fromString: String($0), max: max) }
	}
	
	// 0-3
	// 0-
	func parseOneRange(fromString string: String, max: Int) -> Range<Int>? {
		let split = string.characters.split(separator: "-")
		
		if split.count == 1 {
			guard let lower = Int(String(split[0])) else {
				return nil
			}
			return Range(uncheckedBounds: (lower, max))
		}
		
		guard let lower = Int(String(split[0])), upper = Int(String(split[1])) else {
			return nil
		}
		
		return Range(uncheckedBounds: (lower, upper+1))
	}
}



