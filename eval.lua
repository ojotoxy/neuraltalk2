require 'torch'
require 'nn'
require 'nngraph'
-- exotics
require 'loadcaffe'
-- local imports
local utils = require 'misc.utils'
require 'misc.DataLoader'
require 'misc.DataLoaderRaw'
require 'misc.LanguageModel'
local net_utils = require 'misc.net_utils'

require 'socket'


-------------------------------------------------------------------------------
-- Input arguments and options
-------------------------------------------------------------------------------
cmd = torch.CmdLine()
cmd:text()
cmd:text('Train an Image Captioning model')
cmd:text()
cmd:text('Options')

-- Input paths
cmd:option('-model','','path to model to evaluate')
-- Basic options
cmd:option('-batch_size', 1, 'if > 0 then overrule, otherwise load from checkpoint.')
cmd:option('-num_images', 100, 'how many images to use when periodically evaluating the loss? (-1 = all)')
cmd:option('-language_eval', 0, 'Evaluate language as well (1 = yes, 0 = no)? BLEU/CIDEr/METEOR/ROUGE_L? requires coco-caption code from Github.')
cmd:option('-dump_images', 1, 'Dump images into vis/imgs folder for vis? (1=yes,0=no)')
cmd:option('-dump_json', 1, 'Dump json with predictions into vis folder? (1=yes,0=no)')
cmd:option('-dump_path', 0, 'Write image paths along with predictions into vis json? (1=yes,0=no)')
-- Sampling options
cmd:option('-sample_max', 1, '1 = sample argmax words. 0 = sample from distributions.')
cmd:option('-beam_size', 2, 'used when sample_max = 1, indicates number of beams in beam search. Usually 2 or 3 works well. More is not better. Set this to 1 for faster runtime but a bit worse performance.')
cmd:option('-temperature', 1.0, 'temperature when sampling from distributions (i.e. when sample_max = 0). Lower = "safer" predictions.')
-- For evaluation on a folder of images:
cmd:option('-image_folder', '', 'If this is nonempty then will predict on the images in this folder path')
cmd:option('-image_root', '', 'In case the image paths have to be preprended with a root path to an image folder')
-- For evaluation on MSCOCO images from some split:
cmd:option('-input_h5','','path to the h5file containing the preprocessed dataset. empty = fetch from model checkpoint.')
cmd:option('-input_json','','path to the json file containing additional info and vocab. empty = fetch from model checkpoint.')
cmd:option('-split', 'test', 'if running on MSCOCO images, which split to use: val|test|train')
cmd:option('-coco_json', '', 'if nonempty then use this file in DataLoaderRaw (see docs there). Used only in MSCOCO test evaluation, where we have a specific json file of only test set images.')
-- misc
cmd:option('-backend', 'cudnn', 'nn|cudnn')
cmd:option('-id', 'evalscript', 'an id identifying this run/job. used only if language_eval = 1 for appending to intermediate files')
cmd:option('-seed', 123, 'random number generator seed to use')
cmd:option('-gpuid', 0, 'which gpu to use. -1 = use CPU')
cmd:text()

-------------------------------------------------------------------------------
-- Basic Torch initializations
-------------------------------------------------------------------------------
local opt = cmd:parse(arg)
torch.manualSeed(opt.seed)
torch.setdefaulttensortype('torch.FloatTensor') -- for CPU

if opt.gpuid >= 0 then
  require 'cutorch'
  require 'cunn'
  if opt.backend == 'cudnn' then require 'cudnn' end
  cutorch.manualSeed(opt.seed)
  cutorch.setDevice(opt.gpuid + 1) -- note +1 because lua is 1-indexed
end

-------------------------------------------------------------------------------
-- Load the model checkpoint to evaluate
-------------------------------------------------------------------------------
assert(string.len(opt.model) > 0, 'must provide a model')
local checkpoint = torch.load(opt.model)
-- override and collect parameters
if string.len(opt.input_h5) == 0 then opt.input_h5 = checkpoint.opt.input_h5 end
if string.len(opt.input_json) == 0 then opt.input_json = checkpoint.opt.input_json end
if opt.batch_size == 0 then opt.batch_size = checkpoint.opt.batch_size end
local fetch = {'rnn_size', 'input_encoding_size', 'drop_prob_lm', 'cnn_proto', 'cnn_model', 'seq_per_img'}
for k,v in pairs(fetch) do 
  opt[v] = checkpoint.opt[v] -- copy over options from model
end
local vocab = checkpoint.vocab -- ix -> word mapping

-------------------------------------------------------------------------------
-- Create the Data Loader instance
-------------------------------------------------------------------------------

local function sleep(sec)
  socket.select(nil, nil, sec)
end

-------------------------------------------------------------------------------
-- Load the networks from model checkpoint
-------------------------------------------------------------------------------
local protos = checkpoint.protos
protos.expander = nn.FeatExpander(opt.seq_per_img)
protos.crit = nn.LanguageModelCriterion()
protos.lm:createClones() -- reconstruct clones inside the language model
if opt.gpuid >= 0 then for k,v in pairs(protos) do v:cuda() end end

-------------------------------------------------------------------------------
-- Evaluation fun(ction)
-------------------------------------------------------------------------------
local function basename(str)
	local name = string.gsub(str, "(.*/)(.*)", "%2")
	return name
end

local function eval_split(split, evalopt)
  local verbose = utils.getopt(evalopt, 'verbose', true)
  local num_images = utils.getopt(evalopt, 'num_images', true)

  protos.cnn:evaluate()
  protos.lm:evaluate()
	

  local n = 0
  local loss_sum = 0
  local loss_evals = 0
  local predictions = {}
  while true do
    local loader = DataLoaderRaw{folder_path = opt.image_folder, coco_json = opt.coco_json}
    loader:resetIterator(split) -- rewind iteator back to first datapoint in the split
    -- fetch a batch of data
    local data = loader:getBatch{batch_size = opt.batch_size, split = split, seq_per_img = opt.seq_per_img}
    if data.images:dim() == 0 then
       --no data available	
       sleep(0.2)
    else
	-- data available
	print('data available!')
	    data.images = net_utils.prepro(data.images, false, opt.gpuid >= 0) -- preprocess in place, and don't augment
	    n = n + data.images:size(1)

	    -- forward the model to get loss
	    local feats = protos.cnn:forward(data.images)

	    -- evaluate loss if we have the labels
	    local loss = 0
	    if data.labels then
	      local expanded_feats = protos.expander:forward(feats)
	      local logprobs = protos.lm:forward{expanded_feats, data.labels}
	      loss = protos.crit:forward(logprobs, data.labels)
	      loss_sum = loss_sum + loss
	      loss_evals = loss_evals + 1
	    end

	    -- forward the model to also get generated samples for each image
	    local sample_opts = { sample_max = opt.sample_max, beam_size = opt.beam_size, temperature = opt.temperature }
	    local seq = protos.lm:sample(feats, sample_opts)
	    local sents = net_utils.decode_sequence(vocab, seq)
	    for k=1,#sents do
	      local entry = {image_id = data.infos[k].id, caption = sents[k]}
	      if opt.dump_path == 1 then
		entry.file_name = data.infos[k].file_path
	      end
	      table.insert(predictions, entry)
	      local outname = 'outputs/' .. basename(data.infos[k].file_path) .. '.json'
	      utils.write_json(outname, { caption =  entry.caption } )
	      print('wrote to ' .. outname)
	      if verbose then
		print(string.format('image %s: %s', entry.file_path, entry.caption))
	      end
	    end
    end
		



  end

end

eval_split(opt.split, {num_images = opt.num_images})
